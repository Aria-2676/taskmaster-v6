import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/extension/extension_hook.dart';
import '../../core/plugin/plugin_hook_channel.dart';
import '../data/plugin_bridge.dart';

/// 启动一个插件所需的全部材料。
class PluginLaunchSpec {
  const PluginLaunchSpec({
    required this.title,
    required this.entryPath,
    required this.bridge,
    this.hooks = const <HookId>{},
  });

  final String title;
  final String entryPath;
  final PluginBridge bridge;

  /// manifest 里声明的事件钩子。没声明的不会收到推送。
  final Set<HookId> hooks;
}

/// 插件页的**内容部分**，不含 Scaffold/AppBar。
///
/// 拆出来的原因：插件既可以当一个"打开就进"的页面（[PluginPage]），
/// 也可以**直接当首页**（嵌进主包外壳的内容区）。两种情况只有外壳不同，
/// WebView、桥接、加载回调必须完全一样 —— 否则"当首页时某个接口不好使"
/// 这类问题会只在一种形态下复现。
class PluginView extends StatefulWidget {
  const PluginView({
    super.key,
    required this.entryPath,
    required this.bridge,
    this.hooks = const <HookId>{},
    this.onLoaded,
    this.onError,
  });

  /// 包内入口 HTML 的绝对路径
  final String entryPath;

  final PluginBridge bridge;

  /// 这个插件订阅的事件（来自 manifest）。空集 = 不推任何事件。
  final Set<HookId> hooks;

  /// 首帧加载完成（**每份页面只回调一次**）。首页熔断靠它取消超时计时器。
  final ValueChanged<String>? onLoaded;

  final ValueChanged<String>? onError;

  @override
  State<PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends State<PluginView> {
  late final WebViewController _controller;
  late final PluginHookChannel _channel;
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _channel = PluginHookChannel(
      pluginId: widget.bridge.pluginId,
      hooks: widget.hooks,
      send: _sendEvent,
    );
    if (widget.hooks.isNotEmpty) {
      HookBus.instance.register(_channel);
    }

    final controller = WebViewController();
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    controller.setBackgroundColor(const Color(0x00000000));
    controller.addJavaScriptChannel('HostBridge', onMessageReceived: _onHostMessage);
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) {
          // 页面开始重载：先在本地排队，别往旧页面的 JS 上下文里发
          _channel.markUnready();
          controller.runJavaScript(_bootstrap);
        },
        // 再补一次：有的机型 onPageStarted 时 JS 上下文还没建好
        onPageFinished: (url) {
          controller.runJavaScript(_bootstrap);
          // 桥接脚本就绪 → 把排队的事件补发出去
          _channel.markReady();
          if (_reported) return;
          _reported = true;
          widget.onLoaded?.call(url);
        },
        onWebResourceError: (error) {
          // 只报主文档的错：图片/字体挂了不该把首页判成失败
          if (!error.isForMainFrame.orTrue) return;
          widget.onError?.call(error.description);
        },
      ),
    );
    _controller = controller;
    // **先清缓存再加载**。`file://` 也走 WebView 的磁盘缓存：插件升级后
    // 入口路径没变、内容变了，不清就会一直显示旧页面 —— 用户以为没升成功，
    // 实际是缓存。顺序不能并行：并行时 loadFile 可能先命中旧缓存。
    // 清的是本机 WebView 的资源缓存，本地文件重读代价可以忽略。
    unawaited(() async {
      try {
        await controller.clearCache().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 清缓存失败不该让页面打不开：继续加载，最坏是这一次看到旧页面
      }
      await controller.loadFile(widget.entryPath);
    }());
  }

  @override
  void dispose() {
    // 按实例移除而不是按 pluginId：同一插件可能同时开着两个页面
    HookBus.instance.removeListener(_channel);
    super.dispose();
  }

  void _sendEvent(String event, Map<String, Object?> payload) {
    unawaited(_controller.runJavaScript(
      'window.__hostEvent && window.__hostEvent(${jsonEncode(event)}, ${jsonEncode(payload)});',
    ));
  }

  Future<void> _onHostMessage(JavaScriptMessage message) async {
    final Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = Map<String, Object?>.from(decoded);
    } catch (_) {
      return;
    }

    final id = payload['id'];
    final method = payload['method'];
    if (id is! int || method is! String) return;

    final rawParams = payload['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : const <String, Object?>{};

    final result = await widget.bridge.dispatch(method, params);
    if (!mounted) return;
    await _controller.runJavaScript('window.__hostResolve($id, ${jsonEncode(result)});');
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  /// 注入到插件页面的桥接脚本。**幂等**：重复执行只会 return。
  static const String _bootstrap = r'''
(function () {
  if (window.host) return;
  var seq = 0;
  var pending = {};
  window.__hostResolve = function (id, payload) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    if (payload && payload.ok) {
      entry.resolve(payload.result);
    } else {
      var error = (payload && payload.error) || {};
      entry.reject({ code: error.code || 'unknown', message: error.message || '调用失败' });
    }
  };
  var handlers = {};
  window.host = {
    call: function (method, params) {
      return new Promise(function (resolve, reject) {
        var id = ++seq;
        pending[id] = { resolve: resolve, reject: reject };
        HostBridge.postMessage(JSON.stringify({ id: id, method: method, params: params || {} }));
      });
    },
    // 事件订阅。宿主只推 manifest 里声明过的钩子；
    // 这里再挡一层：同一个事件可以挂多个处理函数，各自 try/catch ——
    // 一个处理函数抛异常不该让后面的收不到。
    on: function (name, fn) {
      if (typeof fn !== 'function') return;
      (handlers[name] = handlers[name] || []).push(fn);
    },
    off: function (name, fn) {
      var list = handlers[name];
      if (!list) return;
      var at = list.indexOf(fn);
      if (at >= 0) list.splice(at, 1);
    }
  };
  window.__hostEvent = function (name, payload) {
    var list = handlers[name];
    if (!list) return;
    for (var i = 0; i < list.length; i++) {
      try { list[i](payload); } catch (e) { /* 单个订阅者出错不影响其他 */ }
    }
  };
})();
''';
}

/// 独立打开的插件页（带标题栏）。
class PluginPage extends StatelessWidget {
  const PluginPage({
    super.key,
    required this.title,
    required this.entryPath,
    required this.bridge,
    this.hooks = const <HookId>{},
  });

  final String title;
  final String entryPath;
  final PluginBridge bridge;
  final Set<HookId> hooks;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 16)),
      ),
      body: PluginView(entryPath: entryPath, bridge: bridge, hooks: hooks),
    );
  }
}

extension on bool? {
  /// `isForMainFrame` 在某些平台上是 null（老版本 API），当作 true 处理：
  /// 宁可多报一次错，也不要因为拿不到标志位而把真正的加载失败吞掉。
  bool get orTrue => this ?? true;
}
