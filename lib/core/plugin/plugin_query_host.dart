import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

import 'plugin_bootstrap.dart';
import 'plugin_manifest.dart';
import 'plugin_query_registry.dart';

/// 离屏宿主向主包转发 `host.call` 的入口。
///
/// core 不能依赖 app 层（`PluginBridge` 在 app），所以由调用方注入 ——
/// 通常就是 `plugin_bridge.dispatch`。
typedef HostDispatch = Future<Map<String, Object?>> Function(
  String method,
  Map<String, Object?> params,
);

/// 离屏查询宿主：为"声明了 `queryEntry` 的插件"维持一个不显示的 WebView，
/// 让主包在**插件页面没打开时**也能查到数据（今日页、全局搜索用）。
///
/// 为什么需要它：入站查询是注入到插件 JS 环境里执行的，页面一关 WebView 就没了。
/// 「不挂 widget 也能加载并执行 JS」已在模拟器上验证过（2026-11-03，见
/// `docs/ai/work/2026-11-03-data-query.md`）。
///
/// **生命周期跟随调用方**（用户定的策略 3）：今日页进来 acquire，离开 releaseAll。
/// 不做"空闲 N 秒销毁"——那个阈值只能靠猜，而且用户离开页面后还占着内存更奇怪。
class PluginQueryHost {
  PluginQueryHost._();

  static final PluginQueryHost instance = PluginQueryHost._();

  final Map<String, _OffscreenPlugin> _plugins = <String, _OffscreenPlugin>{};

  /// 单次查询的等待上限。和前台查询保持一致。
  static const Duration timeout = Duration(seconds: 2);

  /// **离屏页面首次加载**的等待上限。比查询宽松得多：
  /// 新建一个 WebView 实例 + 从文件加载，冷启动要 2 秒以上很常见。
  /// 一开始和查询共用 2 秒，结果页面还没准备好就被判失败、块静默消失
  /// （2026-11-03 在模拟器上撞到）。
  static const Duration readyTimeout = Duration(seconds: 6);

  /// 为插件准备离屏查询环境。
  ///
  /// [installDir] 必须是**绝对路径**（用 `PluginInstaller.directoryOf` 拿），
  /// 不是 `InstalledPlugin.installDir` 那个相对值 —— 传错的话清单读不出来，
  /// 表现为"插件明明装了却查不到"（2026-11-03 踩过）。
  ///
  /// 返回 `false` 表示这个插件**不参与**离屏查询（没声明 `queryEntry`，或清单读不出来）
  /// —— 这不是错误，调用方按"这块没有"处理。
  Future<bool> acquire(
    String pluginId,
    String installDir, {
    required HostDispatch dispatch,
  }) async {
    final existing = _plugins[pluginId];
    if (existing != null) return existing.ready.isCompleted;

    debugPrint('[query-host] 读清单 $installDir');
    final manifest = await _readManifest(installDir);
    debugPrint('[query-host] 清单=${manifest?.id} queryEntry=${manifest?.queryEntry}');
    final entry = manifest?.queryEntry;
    if (entry == null) return false;

    final host = _OffscreenPlugin(pluginId, dispatch);
    _plugins[pluginId] = host;
    final ok = await host.load(p.join(installDir, entry));
    if (!ok) {
      debugPrint('[query-host] $pluginId 离屏页面没在 ${readyTimeout.inSeconds}s 内就绪，'
          '这一轮不参与查询');
      _plugins.remove(pluginId);
      return false;
    }
    // 离屏宿主也登记进 registry，这样业务层只认一个入口（PluginQueryRegistry），
    // 不需要知道数据是"页面活着"还是"离屏"给的。
    PluginQueryRegistry.instance.register(pluginId, host.query);
    return true;
  }

  /// 释放全部离屏实例。今日页 `dispose` 时调。
  Future<void> releaseAll() async {
    final hosts = _plugins.values.toList();
    _plugins.clear();
    for (final host in hosts) {
      PluginQueryRegistry.instance.unregister(host.pluginId);
      await host.dispose();
    }
  }

  /// 只给测试用：当前托管的插件数。
  @visibleForTesting
  int get debugHostCount => _plugins.length;

  Future<PluginManifest?> _readManifest(String installDir) async {
    try {
      // 包内清单是 `plugin.json`（和 PluginInstaller 读同一份），
      // 不是 "manifest.json" —— 写错的话文件不存在，插件明明装了却查不到。
      final file = File(p.join(installDir, 'plugin.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return PluginManifest.parse(Map<String, Object?>.from(decoded));
    } catch (error) {
      // 清单坏了就当"这个插件不参与"，不让一个坏插件拖垮整页
      debugPrint('[query-host] 读清单失败 $installDir：$error');
      return null;
    }
  }
}

class _OffscreenPlugin {
  _OffscreenPlugin(this.pluginId, this._dispatch);

  final String pluginId;
  final HostDispatch _dispatch;
  final WebViewController _controller = WebViewController();
  final Completer<void> ready = Completer<void>();
  final Map<int, Completer<QueryResult>> _pending =
      <int, Completer<QueryResult>>{};
  int _seq = 0;

  Future<bool> load(String absolutePath) async {
    try {
      _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      _controller.addJavaScriptChannel(
        'HostBridge',
        onMessageReceived: _onMessage,
      );
      _controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            // 页面加载完才注入桥接脚本（早于这个时刻会丢）。
            // 注入是异步的，跑完还要等插件那边把 handler 挂上 —— 它用
            // setTimeout 轮询 `window.host`。所以这里**主动确认**而不是假设：
            // 轮询 `typeof window.host` 直到变成 object，再多等一拍给注册。
            await _controller.runJavaScript(pluginBootstrapScript);
            var injected = false;
            for (var i = 0; i < 20; i++) {
              try {
                final probe = await _controller
                    .runJavaScriptReturningResult('typeof window.host');
                if ('$probe'.contains('object')) {
                  injected = true;
                  break;
                }
              } catch (_) {
                // 页面还没就绪，等下一轮
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            debugPrint('[query-host] bootstrap 注入${injected ? "成功" : "失败"}');
            if (!injected) return; // 让 ready 超时，别假装就绪
            await Future<void>.delayed(const Duration(milliseconds: 120));
            if (!ready.isCompleted) ready.complete();
          },
        ),
      );
      debugPrint('[query-host] $pluginId 开始 loadFile $absolutePath');
      await _controller.loadFile(absolutePath);
      debugPrint('[query-host] $pluginId loadFile 返回，等 onPageFinished');
      await ready.future.timeout(PluginQueryHost.readyTimeout);
      debugPrint('[query-host] $pluginId 已就绪');
      return true;
    } catch (error) {
      debugPrint('[query-host] $pluginId 离屏加载失败：$error');
      return false;
    }
  }

  Future<QueryResult> query(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    if (!ready.isCompleted) return const QueryResult.unavailable();
    final id = ++_seq;
    final pending = Completer<QueryResult>();
    _pending[id] = pending;
    try {
      await _controller.runJavaScript(
        'window.__hostQuery && window.__hostQuery($id, ${jsonEncode(method)}, ${jsonEncode(params)});',
      );
    } catch (error) {
      _pending.remove(id);
      debugPrint('[query-host] $pluginId 注入失败 $method：$error');
      return const QueryResult.failed();
    }
    try {
      return await pending.future.timeout(PluginQueryHost.timeout);
    } on TimeoutException {
      _pending.remove(id);
      debugPrint('[query-host] $pluginId 查询超时 $method');
      return const QueryResult.timeout();
    }
  }

  Future<void> _onMessage(JavaScriptMessage message) async {
    Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = Map<String, Object?>.from(decoded);
    } catch (_) {
      return;
    }
    // 插件注册完 handler 后的就绪信号
    if (payload['queryReady'] == true) {
      if (!ready.isCompleted) ready.complete();
      return;
    }

    final replyId = payload['queryReply'];
    if (replyId is int) {
      final pending = _pending.remove(replyId);
      if (pending == null || pending.isCompleted) return;
      pending.complete(_resultOf(payload));
      return;
    }

    // 插件在离屏页面里调 host.call（例如 task.list）：离屏宿主同样要转发，
    // 否则 handler 里的 await 永远不返回，查询必然超时。
    final id = payload['id'];
    final method = payload['method'];
    if (id is! int || method is! String) return;
    final rawParams = payload['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : const <String, Object?>{};
    Map<String, Object?> result;
    try {
      result = await _dispatch(method, params);
    } catch (error) {
      result = <String, Object?>{
        'ok': false,
        'error': <String, Object?>{'code': 'failed', 'message': '$error'},
      };
    }
    await _controller.runJavaScript('window.__hostResolve($id, ${jsonEncode(result)});');
  }

  /// 把插件回包翻译成结果对象。`unsupported` 要和普通失败分开 ——
  /// 前者是"这个插件没这个能力"，不该被失败记忆永久跳过。
  static QueryResult _resultOf(Map<String, Object?> payload) {
    if (payload['ok'] == true) {
      final result = payload['result'];
      return result is Map
          ? QueryResult.ok(Map<String, Object?>.from(result))
          : const QueryResult.failed();
    }
    final error = payload['error'];
    final code = error is Map ? error['code'] : null;
    return code == 'unsupported'
        ? const QueryResult.unsupported()
        : const QueryResult.failed();
  }

  Future<void> dispose() async {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.complete(const QueryResult.unavailable());
      }
    }
    _pending.clear();
    try {
      await _controller.loadHtmlString('<html><body></body></html>');
    } catch (_) {
      // 释放失败无所谓：WebView 没有显式 destroy，只能靠丢引用让 GC 收
    }
  }
}
