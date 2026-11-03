import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/extension/extension_hook.dart';
import '../../core/plugin/plugin_hook_channel.dart';
import '../../core/plugin/plugin_bootstrap.dart';
import '../../core/plugin/plugin_query_registry.dart';
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

  /// 入站查询：callId → 等待插件回包的 Completer。
  int _querySeq = 0;
  final Map<int, Completer<QueryResult>> _queryPending =
      <int, Completer<QueryResult>>{};

  /// 单次查询的等待上限。超时就当"这个插件没结果"，绝不让调用方一直转圈。
  static const Duration _queryTimeout = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _channel = PluginHookChannel(
      pluginId: widget.bridge.pluginId,
      hooks: widget.hooks,
      send: _sendEvent,
    );
    // 页面存活期间，主包可以按 pluginId 向它发起查询（今日页/全局搜索用）。
    // 同一插件开两个页面时后者覆盖前者：最小版先这样，等真的需要并发再按实例区分。
    PluginQueryRegistry.instance.register(widget.bridge.pluginId, query);
    if (widget.hooks.isNotEmpty) {
      HookBus.instance.register(_channel);
    }

    final controller = WebViewController();
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    // 把插件页的 console 转到 logcat。
    //
    // release 包里 WebView 的 console **哪里都看不到**（没有 DevTools 可连），
    // 而插件的错误恰好只会出现在这里 —— 6.1.0 就是因为看不见插件里的
    // console.warn，多花了一小时才定位到"事件补发被权限拒掉"。
    // 截断到 300 字符：插件的调试输出可能很长，刷屏反而掩盖有用的那行。
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setOnConsoleMessage((message) {
        final text = message.message;
        debugPrint('[plugin:${widget.bridge.pluginId}] ${message.level.name} '
            '${text.length > 300 ? '${text.substring(0, 300)}…' : text}');
      }));
    }
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
    PluginQueryRegistry.instance.unregister(widget.bridge.pluginId);
    // 页面没了，等着的查询永远等不到回包 —— 立刻结束，别让调用方卡到超时
    for (final pending in _queryPending.values) {
      if (!pending.isCompleted) pending.complete(const QueryResult.unavailable());
    }
    _queryPending.clear();
    super.dispose();
  }

  void _sendEvent(String event, Map<String, Object?> payload) {
    unawaited(_controller.runJavaScript(
      'window.__hostEvent && window.__hostEvent(${jsonEncode(event)}, ${jsonEncode(payload)});',
    ));
  }

  /// 向插件发起一条查询。结果用 [QueryResult] 区分"没实现/超时/失败" ——
  /// 失败记忆需要这个区别，否则会把"本来就不支持"的插件永久跳过。
  ///
  /// 不抛异常：调用方（今日页、全局搜索）要的是"有就显示、没有就降级"，
  /// 一个插件答不上来不该让整页报错。
  Future<QueryResult> query(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    final id = ++_querySeq;
    final pending = Completer<QueryResult>();
    _queryPending[id] = pending;
    try {
      await _controller.runJavaScript(
        'window.__hostQuery && window.__hostQuery($id, ${jsonEncode(method)}, ${jsonEncode(params)});',
      );
    } catch (error) {
      _queryPending.remove(id);
      debugPrint('[plugin:${widget.bridge.pluginId}] 查询注入失败 $method: $error');
      return const QueryResult.failed();
    }
    try {
      return await pending.future.timeout(_queryTimeout);
    } on TimeoutException {
      _queryPending.remove(id);
      debugPrint('[plugin:${widget.bridge.pluginId}] 查询超时 $method');
      return const QueryResult.timeout();
    }
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

    // 入站查询的回包：先认它，再走原来的 host.call 分支
    final replyId = payload['queryReply'];
    if (replyId is int) {
      final pending = _queryPending.remove(replyId);
      if (pending != null && !pending.isCompleted) {
        final result = payload['result'];
        final error = payload['error'];
        final code = error is Map ? error['code'] : null;
        pending.complete(
          payload['ok'] == true
              ? (result is Map
                  ? QueryResult.ok(Map<String, Object?>.from(result))
                  : const QueryResult.failed())
              : (code == 'unsupported'
                  ? const QueryResult.unsupported()
                  : const QueryResult.failed()),
        );
      }
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

  /// 注入到插件页面的桥接脚本。内容在 core 层，离屏查询宿主共用同一份。
  static const String _bootstrap = pluginBootstrapScript;

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
