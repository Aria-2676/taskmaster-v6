import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/services/local_notification_service.dart';
import '../models/task.dart';

/// 把任务的提醒时间排进系统闹钟。
///
/// 为什么是单例而不是注入：`TaskStore` 的每个写入口（新建/编辑/完成/删除）
/// 都要跟着重排，逐个往下传一个可选回调会让构造参数爆炸，还容易漏。
/// 单例 + 未初始化时空转，测试里不用搭这套东西也能跑。
///
/// **不精确降级、过点立即发、失败只记日志** 这些都在
/// [LocalNotificationService.scheduleAt] 里处理了，这里只管"该排的排、该取消的取消"。
class TaskReminderScheduler {
  TaskReminderScheduler._();

  static final TaskReminderScheduler instance = TaskReminderScheduler._();

  /// 通知 id 的偏移。
  ///
  /// 番茄钟占了 `0x7071` / `0x7072`，插件用的是自增小号；任务从 `0x8000` 起，
  /// 和两边都不撞。任务 id 是自增整数，短期内不可能涨到 0x8000。
  static const int _idBase = 0x8000;

  NotificationSink? _sink;

  /// 由应用层在启动时注入。没注入时所有方法都是空转。
  void attach(NotificationSink sink) => _sink = sink;

  static int notificationIdFor(int taskId) => _idBase + taskId;

  /// 把 `yyyy-MM-dd HH:mm` 解析成当地时间。格式不对返回 null（当作没有提醒）。
  static DateTime? parseRemindAt(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final text = raw.trim();
    // 只到分钟，补上秒再交给 DateTime.parse
    final normalized = text.length == 16 ? '$text:00' : text;
    return DateTime.tryParse(normalized.replaceFirst(' ', 'T'));
  }

  /// 构造存库用的字符串（`yyyy-MM-dd HH:mm`）。
  static String formatRemindAt(DateTime at) {
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    final h = at.hour.toString().padLeft(2, '0');
    final min = at.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  /// 任务保存/完成后调用：该排的排、该撤的撤。
  Future<void> sync(Task task) async {
    final sink = _sink;
    if (sink == null) return;
    final id = notificationIdFor(task.id);
    final at = parseRemindAt(task.remindAt);

    // 没有提醒、已完成、时间已经过去 —— 都不该留着一个不会响的闹钟
    if (at == null || task.isDone || !at.isAfter(DateTime.now())) {
      try {
        await sink.cancel(id);
      } catch (error) {
        debugPrint('[remind] 取消失败 id=$id：$error');
      }
      return;
    }

    try {
      final result = await sink.scheduleAt(
        id: id,
        at: at,
        title: task.title,
        body: '到点了',
        channelId: LocalNotificationService.channelTask,
      );
      debugPrint('[remind] 排期任务 ${task.id} 结果=$result at=$at');
    } catch (error) {
      // 排不上不该影响任务本身保存成功
      debugPrint('[remind] 排期失败 id=$id：$error');
    }
  }

  /// 启动时整体重排。
  ///
  /// 三种情况会丢闹钟：设备重启（靠 BootReceiver 恢复）、App 升级、
  /// 用户清数据/换时区。前一种由插件库的 BootReceiver 兜，后两种只能靠启动时重排。
  /// 逐条串行而不是并发：几十条的量级，并发反而容易撞到系统的闹钟限流。
  Future<void> resyncAll(Iterable<Task> tasks) async {
    if (_sink == null) return;
    var scheduled = 0;
    for (final task in tasks) {
      if (parseRemindAt(task.remindAt) == null) continue;
      await sync(task);
      scheduled++;
    }
    if (scheduled > 0) {
      debugPrint('[remind] 启动重排 $scheduled 条');
    }
  }
}
