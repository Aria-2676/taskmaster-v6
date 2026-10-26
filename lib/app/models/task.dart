import 'package:flutter/material.dart';

import '../../core/data/v6_schema.dart';

/// v6 的任务模型。**不含任何货币字段**——`reward_points` / `is_deducted` 已随货币插件移出主包。
///
/// 日期约定（与 [V6Table.tasks] 的表结构对应）：
/// - `dueDate` 对应 `cpl_time`，**只到天**，以 `yyyy-MM-dd` 存储（按日期查任务走索引）
/// - `createdAt` / `completedAt` 是完整时间戳
class Task {
  const Task({
    required this.id,
    required this.title,
    required this.dueDate,
    required this.priority,
    required this.isDone,
    this.description,
    this.estimatedMinutes,
    this.createdAt,
    this.completedAt,
    this.tags = const <Tag>[],
  });

  factory Task.fromRow(Map<String, Object?> row, {List<Tag> tags = const <Tag>[]}) {
    return Task(
      id: row[TaskCol.id]! as int,
      title: row[TaskCol.title] as String? ?? '',
      description: row[TaskCol.description] as String?,
      dueDate: TaskDate.parseDay(row[TaskCol.cplTime] as String),
      priority: row[TaskCol.priority] as String? ?? 'white',
      isDone: (row[TaskCol.isOk] as int? ?? 0) != 0,
      estimatedMinutes: row[TaskCol.estimatedMinutes] as int?,
      createdAt: TaskDate.parseTime(row[TaskCol.createdAt] as String?),
      completedAt: TaskDate.parseTime(row[TaskCol.completedAt] as String?),
      tags: tags,
    );
  }

  final int id;
  final String title;
  final String? description;

  /// 属于哪一天（本地日期，零点）
  final DateTime dueDate;

  /// red / orange / yellow / blue / white
  final String priority;

  final bool isDone;

  /// 预计工时（分钟）。主包只存不解释，计价归货币插件
  final int? estimatedMinutes;

  final DateTime? createdAt;
  final DateTime? completedAt;

  final List<Tag> tags;

  Task copyWith({bool? isDone, DateTime? completedAt}) => Task(
        id: id,
        title: title,
        description: description,
        dueDate: dueDate,
        priority: priority,
        isDone: isDone ?? this.isDone,
        estimatedMinutes: estimatedMinutes,
        createdAt: createdAt,
        completedAt: completedAt ?? this.completedAt,
        tags: tags,
      );

  Color get priorityColor => switch (priority) {
        'red' => const Color(0xFFE53935),
        'orange' => const Color(0xFFFB8C00),
        'yellow' => const Color(0xFFFDD835),
        'blue' => const Color(0xFF1E88E5),
        _ => const Color(0xFFBDBDBD),
      };

  /// 事件钩子的负载。
  ///
  /// 只放**订阅方能算出结果**的字段：估时、优先级、标签都在里面，
  /// 货币插件据此结算就不必再回查一次库（也就不会读到"已经变了"的版本）。
  /// 不放描述：那是用户写给自己的，插件没有理由看到。
  Map<String, Object?> toHookPayload() => <String, Object?>{
        'taskId': id,
        'title': title,
        'dueDate': TaskDate.dayKey(dueDate),
        'priority': priority,
        'estimatedMinutes': estimatedMinutes,
        'tags': <String>[for (final tag in tags) tag.name],
      };
}

class Tag {
  const Tag({required this.id, required this.name, this.color = '#2196F3'});

  final int id;
  final String name;

  /// `#RRGGBB`
  final String color;

  Color get displayColor {
    final hex = color.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return const Color(0xFF2196F3);
    return Color(0xFF000000 | value);
  }
}

/// 日期格式化/解析的**唯一入口**。
///
/// 存字符串而不是毫秒时间戳，是为了让 `WHERE cpl_time = ?` 能直接命中索引，
/// 也让 `sqlite3` 命令行里看到的是人眼可读的日期。
class TaskDate {
  const TaskDate._();

  /// `2026-10-22`（本地日期，不带时区）
  static String dayKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static DateTime parseDay(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return DateTime.now();
    return DateTime(
      int.tryParse(parts[0]) ?? 1970,
      int.tryParse(parts[1]) ?? 1,
      int.tryParse(parts[2]) ?? 1,
    );
  }

  /// 完整时间戳（UTC 存储，读取时转本地）
  static String timeKey(DateTime d) => d.toUtc().toIso8601String();

  static DateTime? parseTime(String? s) =>
      s == null ? null : DateTime.tryParse(s)?.toLocal();
}
