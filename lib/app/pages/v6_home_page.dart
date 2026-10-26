import 'package:flutter/material.dart';

import '../models/calendar_strip_style.dart';
import '../models/task.dart';
import '../widgets/calendar_strip.dart';
import '../widgets/task_card.dart';

/// 第一屏主体：日历条 + 标签筛选 + 任务列表。
///
/// 数据由外层 `MainShell` 从 `TaskStore` 取；本页不再自己存列表，
/// 避免"两处都可能改状态"的经典问题。
class V6HomePage extends StatelessWidget {
  const V6HomePage({
    super.key,
    required this.selected,
    required this.tasks,
    required this.tags,
    required this.onSelectDate,
    required this.onToggle,
    required this.onBeforeDelete,
    required this.onDeleted,
    this.overdue = const <Task>[],
    this.onMoveOverdueToSelectedDay,
    this.onEdit,
    this.tagFilter,
    this.onSelectTag,
    this.calendarStyle = CalendarStripStyle.scroll,
    this.resetSignal = 0,
    this.marks,
    this.extraLineFor,
  });

  final DateTime selected;
  final List<Task> tasks;

  /// 比 [selected] 更早、还没做完的任务。
  ///
  /// 放在同一天里显示，是因为**逾期任务不能靠用户回翻日期去找** ——
  /// 谁也不会每天往前翻三天看有没有漏的。
  final List<Task> overdue;

  /// 「全部移到今天」（其实是移到当前选中的那天）。为 null 时不显示该按钮。
  final VoidCallback? onMoveOverdueToSelectedDay;

  final List<Tag> tags;
  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<Task> onToggle;

  /// 左滑到底时先问一句"要不要删"。返回 false 卡片会弹回原位。
  final Future<bool> Function(Task task) onBeforeDelete;

  /// 用户已经确认，Dismissible 也已播完消失动画 —— 此时才真正写库。
  final ValueChanged<Task> onDeleted;

  /// 点卡片正文进编辑。为 null 时正文不可点。
  final ValueChanged<Task>? onEdit;

  /// null 表示"全部"
  final String? tagFilter;
  final ValueChanged<String?>? onSelectTag;

  final CalendarStripStyle calendarStyle;
  final int resetSignal;
  final Map<DateTime, String>? marks;

  /// 插槽 `slot.taskCardExtra` 的取值函数；返回 null 表示这张卡片没有附加行。
  final String? Function(Task task)? extraLineFor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: CalendarStrip(
            selected: selected,
            onSelect: onSelectDate,
            style: calendarStyle,
            resetSignal: resetSignal,
            marks: marks,
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: tags.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final label = i == 0 ? '全部' : tags[i - 1].name;
              final value = i == 0 ? null : tags[i - 1].name;
              return _FilterChip(
                label: label,
                selected: tagFilter == value,
                onTap: onSelectTag == null ? null : () => onSelectTag!(value),
              );
            },
          ),
        ),
        Expanded(
          child: (tasks.isEmpty && overdue.isEmpty)
              ? const _EmptyState()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  children: <Widget>[
                    if (overdue.isNotEmpty) ..._buildOverdue(context),
                    if (overdue.isNotEmpty && tasks.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
                        child: Text(
                          '当天',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    for (final task in tasks) _taskTile(task),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _taskTile(Task task, {int? overdueDays}) {
    return Dismissible(
      key: ValueKey<int>(task.id),
      direction: DismissDirection.endToStart,
      background: const _RecycleBackground(),
      // 确认放在 confirmDismiss：返回 false 时卡片会回弹，
      // 而不是"已经飞走了再告诉你删不掉"
      confirmDismiss: (_) => onBeforeDelete(task),
      onDismissed: (_) => onDeleted(task),
      child: TaskCard(
        task: task,
        overdueDays: overdueDays,
        onToggle: () => onToggle(task),
        onOpen: onEdit == null ? null : () => onEdit!(task),
        extraLine: extraLineFor?.call(task),
      ),
    );
  }

  /// 逾期区。最多摆 3 条 —— 再多就会把当天的任务挤到屏幕外，
  /// 那等于用"提醒你还有 20 条没做完"把今天要做的事盖住。
  List<Widget> _buildOverdue(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const visible = 3;
    final shown = overdue.take(visible).toList();
    final rest = overdue.length - shown.length;

    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
        child: Row(
          children: <Widget>[
            Text(
              '逾期 ${overdue.length} 条',
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
            const Spacer(),
            if (onMoveOverdueToSelectedDay != null)
              TextButton(
                onPressed: onMoveOverdueToSelectedDay,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('全部移到这天', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
      for (final task in shown)
        _taskTile(
          task,
          overdueDays: selected.difference(task.dueDate).inDays,
        ),
      if (rest > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            '另有 $rest 条更早的逾期任务，先完成上面这几条就好',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ),
    ];
  }
}

/// 左滑时露出的回收站底色。
class _RecycleBackground extends StatelessWidget {
  const _RecycleBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(right: 20),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.task_alt, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            '这一天还没有任务',
            style: TextStyle(fontSize: 13, color: theme.textTheme.bodySmall?.color),
          ),
        ],
      ),
    );
  }
}
