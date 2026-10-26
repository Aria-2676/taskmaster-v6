import 'dart:async';

import '../models/task.dart';

/// "已确认删除、正在等 `Dismissible` 播完动画"的任务登记表。
///
/// 正常路径：动画结束回调 [cancel]，调用方立刻写库。
/// 兜底路径：动画没走完（历史上出现过：卡片卡在滑出位置，`onDismissed` 不触发），
/// 超时后由 [onExpired] 执行删除 —— 于是"删不删得掉"不再取决于那段动画。
///
/// 单独抽出来是为了能被测试：这条路径正常使用时几乎走不到，
/// 永远没法靠"手动再试一次"来验证它是否还有效。
class PendingDeleteGuard {
  PendingDeleteGuard({
    required this.onExpired,
    this.timeout = const Duration(milliseconds: 700),
  });

  /// 超时后真正执行删除的回调
  final void Function(Task task) onExpired;
  final Duration timeout;

  final Map<int, Task> _tasks = <int, Task>{};
  final Map<int, Timer> _timers = <int, Timer>{};

  void schedule(Task task) {
    _tasks[task.id] = task;
    _timers[task.id]?.cancel();
    _timers[task.id] = Timer(timeout, () {
      _timers.remove(task.id);
      final pending = _tasks.remove(task.id);
      if (pending == null) return;
      onExpired(pending);
    });
  }

  /// 动画正常结束、交给调用方执行删除时调它：只取消定时器。
  ///
  /// **不要用它的返回值决定"该不该删"** —— 这正是出过 bug 的地方：
  /// 确认框关闭时 `confirmDismiss` 直接放行、没有登记，于是 `onDismissed`
  /// 认为"轮不到我"，一条都没删，任务只是从界面消失。
  /// 现在删除的幂等性由调用方保证（不在列表里就跳过），这里只负责收尾。
  void cancel(int taskId) {
    _timers.remove(taskId)?.cancel();
    _tasks.remove(taskId);
  }

  /// 是否还有等待中的任务（诊断用）
  int get pendingCount => _tasks.length;

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _tasks.clear();
  }
}
