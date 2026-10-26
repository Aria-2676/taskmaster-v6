import 'dart:collection';

import '../extension/extension_hook.dart';

/// 把主包事件推给某个插件的通道（host → plugin）。
///
/// 三个必须处理好的时机问题：
///
/// 1. **页面还没加载完就有事件**。用户可能在插件页还在转圈时完成了任务。
///    直接 `runJavaScript` 会丢，所以先排队；页面报"加载完成"后再按顺序补发。
/// 2. **页面永远加载不出来**。队列必须有上限，否则一个坏插件能把内存吃满。
/// 3. **插件没声明这个钩子**。不推 —— 声明是契约，不是"想听什么随便听"。
///
/// 推送失败**一律吞掉**：插件收不到事件是它的损失，不能让主流程失败。
class PluginHookChannel implements HookListener {
  PluginHookChannel({
    required this.pluginId,
    required Set<HookId> hooks,
    required this.send,
    this.maxQueued = 20,
  }) : hooks = Set<HookId>.unmodifiable(hooks);

  @override
  final String pluginId;

  /// 该插件在 manifest 里声明的钩子
  @override
  final Set<HookId> hooks;

  /// 真正发出去（通常是 `runJavaScript`）。测试里注入假实现。
  final void Function(String event, Map<String, Object?> payload) send;

  /// 最多攒多少个事件。超了丢最老的 —— 新事件更能反映当前状态。
  final int maxQueued;

  final Queue<HookEvent> _queue = Queue<HookEvent>();
  bool _ready = false;

  bool get ready => _ready;

  /// 队列里还有多少没发出去
  int get queued => _queue.length;

  /// 页面加载完成（`onPageFinished`）。补发期间来的新事件直接发。
  void markReady() {
    _ready = true;
    while (_queue.isNotEmpty) {
      _dispatch(_queue.removeFirst());
    }
  }

  /// 页面要重载/销毁：回到排队状态，避免往已经不存在的页面里发
  void markUnready() => _ready = false;

  @override
  Future<void> onEvent(HookEvent event) async {
    if (!hooks.contains(event.hook)) return;
    if (!_ready) {
      if (_queue.length >= maxQueued) _queue.removeFirst();
      _queue.add(event);
      return;
    }
    _dispatch(event);
  }

  void _dispatch(HookEvent event) {
    try {
      send(event.hook.id, event.payload);
    } catch (_) {
      // 宿主侧发送失败（页面已销毁、JS 通道异常）不该影响调用方
    }
  }
}
