import '../../core/data/v6_schema.dart';
import 'task.dart';

/// 回收站里的一条记录。
///
/// 和 [Task] 分开一个类型，是因为它们**语义不同**：这里有删除时间、
/// 有原任务 id、有标签快照（`tag_ids`，恢复时用来重建 `task_tags`）。
/// 用同一个类会让"删了之后还能恢复成什么样"变成隐藏行为。
class RecycledTask {
  const RecycledTask({
    required this.id,
    required this.title,
    required this.dueDate,
    required this.priority,
    required this.isDone,
    this.taskId,
    this.deletedAt,
    this.tagIds = const <int>[],
  });

  factory RecycledTask.fromRow(Map<String, Object?> row) => RecycledTask(
        id: row[RecycledTaskCol.id]! as int,
        taskId: row[RecycledTaskCol.taskId] as int?,
        title: row[RecycledTaskCol.title] as String? ?? '',
        dueDate: TaskDate.parseDay(row[RecycledTaskCol.cplTime] as String),
        priority: row[RecycledTaskCol.priority] as String? ?? 'white',
        isDone: (row[RecycledTaskCol.isOk] as int? ?? 0) != 0,
        deletedAt: TaskDate.parseTime(row[RecycledTaskCol.deletedAt] as String?),
        tagIds: (row[RecycledTaskCol.tagIds] as String?)
                ?.split(',')
                .map(int.tryParse)
                .whereType<int>()
                .toList() ??
            const <int>[],
      );

  /// `recycled_tasks.id`（不是原任务 id）
  final int id;

  /// 原任务的 `tasks.id`，仅用于排查
  final int? taskId;

  final String title;
  final DateTime dueDate;
  final String priority;
  final bool isDone;
  final DateTime? deletedAt;

  /// 删除时这条任务拥有的标签 id（恢复时按它重建关联）
  final List<int> tagIds;

  /// 还有几天会被自动清理（向上取整，最小 0）
  int daysLeft(int retentionDays) {
    final deleted = deletedAt;
    if (deleted == null) return 0;
    final expireAt = deleted.add(Duration(days: retentionDays));
    final left = expireAt.difference(DateTime.now()).inHours;
    if (left <= 0) return 0;
    return (left / 24).ceil();
  }
}
