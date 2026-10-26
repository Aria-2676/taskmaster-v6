// v6 扩展位骨架 —— 事件钩子（行为扩展）。
//
// 约定见 docs/plugin-contract.md §4.2 与 .trae/rules/rule-8：
//   1. 钩子是**通知**，不是拦截：插件拿不到"取消这次操作"的权力
//   2. 单个监听器超时（默认 500ms）或抛异常 → 记日志后忽略，**不影响主流程、不影响其他监听器**
//   3. **无人订阅时主流程必须完整可用**——这是插件的存在前提

/// 钩子 id 白名单。
enum HookId {
  /// 任务标记完成。积分插件订阅它来发放积分
  taskCompleted('task.completed'),

  /// 任务进入回收站
  taskRecycled('task.recycled'),

  /// 任务从回收站恢复
  taskRestored('task.restored'),

  /// 一次番茄钟会话结束。
  ///
  /// 计时引擎在主包，**会话记录归番茄钟插件**：插件订阅此钩子写入 `plg_pomodoro_records`。
  /// 没装插件时不落库，主包只计时与通知。
  pomodoroSessionFinished('pomodoro.sessionFinished');

  const HookId(this.id);

  final String id;
}

class HookEvent {
  const HookEvent({required this.hook, this.payload = const <String, Object?>{}});

  final HookId hook;

  /// 只读快照；插件不得依赖此对象修改主包状态
  final Map<String, Object?> payload;
}

abstract class HookListener {
  String get pluginId;

  Set<HookId> get hooks;

  Future<void> onEvent(HookEvent event);
}

/// 钩子总线。
class HookBus {
  HookBus._();

  static final HookBus instance = HookBus._();

  static const Duration defaultTimeout = Duration(milliseconds: 500);

  /// 出错时的上报口子。骨架阶段为 null（静默吞掉），
  /// 接线时指向项目已有的 ErrorHandler / StatisticService。
  void Function(String pluginId, HookId hook, Object error)? onError;

  final Map<HookId, List<HookListener>> _listeners = <HookId, List<HookListener>>{};

  void register(HookListener listener) {
    for (final hook in listener.hooks) {
      (_listeners[hook] ??= <HookListener>[]).add(listener);
    }
  }

  void unregister(String pluginId) {
    for (final list in _listeners.values) {
      list.removeWhere((l) => l.pluginId == pluginId);
    }
  }

  /// 按实例精确移除。
  ///
  /// 为什么不能只用 [unregister]：同一个插件可能同时开着两个页面
  /// （比如它既当首页、又从侧边栏打开了一份），按 id 移除会把还活着的那份也摘掉。
  void removeListener(HookListener listener) {
    for (final list in _listeners.values) {
      list.remove(listener);
    }
  }

  /// 派发事件。**永不抛出**，并在 [timeout] 内必然返回。
  ///
  /// 调用方可直接 `await`，也可 `unawaited`；无论哪种都不会拖垮主流程。
  Future<void> emit(
    HookId hook, {
    Map<String, Object?> payload = const <String, Object?>{},
    Duration timeout = defaultTimeout,
  }) async {
    final targets = _listeners[hook];
    if (targets == null || targets.isEmpty) return;

    final event = HookEvent(hook: hook, payload: payload);
    await Future.wait(
      List<HookListener>.of(targets).map((l) => _dispatch(l, event, timeout)),
    );
  }

  Future<void> _dispatch(HookListener listener, HookEvent event, Duration timeout) async {
    try {
      await listener.onEvent(event).timeout(timeout);
    } catch (error) {
      onError?.call(listener.pluginId, event.hook, error);
    }
  }

  int listenerCount(HookId hook) => _listeners[hook]?.length ?? 0;

  void clear() => _listeners.clear();
}
