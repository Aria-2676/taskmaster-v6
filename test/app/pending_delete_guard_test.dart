// 兜底删除的契约测试。
//
// 这条路径在正常使用中几乎走不到（Dismissible 的动画会正常回调），
// 所以它**不可能靠手动操作来验证**。只能像这样把逻辑抽出来单测。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/state/pending_delete_guard.dart';

Task _task(int id) => Task(
      id: id,
      title: 'task $id',
      dueDate: DateTime(2026, 10, 22),
      priority: 'white',
      isDone: false,
    );

void main() {
  testWidgets('动画没回调时，超时会自己执行删除', (tester) async {
    final fired = <int>[];
    final guard = PendingDeleteGuard(onExpired: (t) => fired.add(t.id));
    addTearDown(guard.dispose);

    guard.schedule(_task(7));
    expect(fired, isEmpty, reason: '还没到点，不该立刻删');
    expect(guard.pendingCount, 1);

    await tester.pump(const Duration(milliseconds: 800));

    expect(fired, <int>[7], reason: 'onDismissed 没来，兜底必须接手');
    expect(guard.pendingCount, 0);
  });

  testWidgets('正常回调之后，兜底不再触发', (tester) async {
    final fired = <int>[];
    final guard = PendingDeleteGuard(onExpired: (t) => fired.add(t.id));
    addTearDown(guard.dispose);

    guard.schedule(_task(7));
    guard.cancel(7);

    await tester.pump(const Duration(milliseconds: 800));

    expect(fired, isEmpty, reason: '已经处理过了，兜底不该再删一次');
  });

  testWidgets('重复 cancel 不会抛，也不会把定时器留给别人', (tester) async {
    final fired = <int>[];
    final guard = PendingDeleteGuard(onExpired: (t) => fired.add(t.id));
    addTearDown(guard.dispose);

    guard.schedule(_task(7));
    guard.cancel(7);
    guard.cancel(7); // 兜底已经取消过了，再来一次是空操作
    expect(guard.pendingCount, 0);

    await tester.pump(const Duration(milliseconds: 800));
    expect(fired, isEmpty);
  });

  testWidgets('cancel 一个从没登记过的任务也安全', (tester) async {
    final fired = <int>[];
    final guard = PendingDeleteGuard(onExpired: (t) => fired.add(t.id));
    addTearDown(guard.dispose);

    guard.cancel(99); // 没 schedule 过
    await tester.pump(const Duration(milliseconds: 800));
    expect(fired, isEmpty);
  });

  testWidgets('未确认删除的任务不会被兜底误删', (tester) async {
    final fired = <int>[];
    final guard = PendingDeleteGuard(onExpired: (t) => fired.add(t.id));
    addTearDown(guard.dispose);

    // 只 schedule 了一个，另一个从未登记
    guard.schedule(_task(1));
    await tester.pump(const Duration(milliseconds: 800));

    expect(fired, <int>[1]);
  });
}
