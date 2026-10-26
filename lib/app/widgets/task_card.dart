import 'package:flutter/material.dart';

import '../models/task.dart';

/// 任务卡片。第四行位置留给「附加行」插槽（`slot.taskCardExtra`，由插件供数据、主包绘制）。
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.onToggle,
    this.onOpen,
    this.extraLine,
    this.overdueDays,
  });

  final Task task;
  final VoidCallback onToggle;

  /// 点正文进编辑。为 null 时正文不可点（测试里不关心编辑时就不传）。
  final VoidCallback? onOpen;

  /// 插槽 `slot.taskCardExtra` 的展示位。没有插件时恒为 null，卡片不会多出一行。
  final String? extraLine;

  /// 逾期几天。null = 不标（当天任务）。
  ///
  /// 逾期任务和当天任务混在一起时，**必须能一眼分开** ——
  /// 否则用户会以为这条是今天新建的，然后奇怪"我什么时候加的"。
  final int? overdueDays;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.color;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                task.isDone ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: task.isDone ? scheme.primary : muted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              // 只让"正文"可点：左边那个勾选圈是独立的点击区，
              // 两者叠在一起会出现"想勾选却进了编辑页"
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: task.priorityColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            decoration:
                                task.isDone ? TextDecoration.lineThrough : null,
                            color: task.isDone ? muted : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (task.tags.isNotEmpty ||
                      task.estimatedMinutes != null ||
                      overdueDays != null) ...<Widget>[
                    const SizedBox(height: 6),
                    // **不截断标签**：以前是 `take(2)`，第三个标签直接消失且没有任何提示，
                    // 用户会以为"标签没保存上"。改成 Wrap 自然换行 —— 多几个标签就把卡片撑高，
                    // 看得见比好看重要。
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (overdueDays != null)
                          _OverdueChip(days: overdueDays!),
                        for (final tag in task.tags)
                          _TagChip(label: tag.name, color: tag.displayColor),
                        if (task.estimatedMinutes != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.schedule, size: 12, color: muted),
                              const SizedBox(width: 3),
                              Text(
                                '${task.estimatedMinutes} 分钟',
                                style: TextStyle(fontSize: 11, color: muted),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                  if (extraLine != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(extraLine!, style: TextStyle(fontSize: 11, color: muted)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverdueChip extends StatelessWidget {
  const _OverdueChip({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        days <= 1 ? '逾期 1 天' : '逾期 $days 天',
        style: TextStyle(fontSize: 11, color: scheme.error),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {  const _TagChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
