import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../utils/app_logger.dart';

/// 排期结果。**不返回 bool**：用户需要知道的是"到点会不会准时响"，
/// 而"排上了但可能晚几分钟"和"排上了且准时"是两件事。
enum NotificationScheduleResult {
  /// 精确闹钟排上了。
  exact,

  /// 系统不给精确闹钟权限，退化成不精确（可能晚几分钟）。
  inexact,

  /// 通知权限被拒 —— 排了也不会显示。
  denied,

  /// 其他失败（原始错误已记日志）。
  failed,
}

/// 通知能力的接口。
///
/// 存在的唯一理由：让"到底有没有去排提醒"能被测试断言。
/// 番茄钟第一版就在这儿栽过 —— 装配时忘了注入通知服务，`_notifications` 是 null，
/// 所有通知调用静默 return：不弹权限框、不排闹钟、到点什么都不发生，
/// 而单测全绿（因为单测也没传通知服务）。有接口才能塞假实现。
abstract class NotificationSink {
  Future<bool> requestPermission();

  Future<void> show({
    required int id,
    required String title,
    required String body,
    String channelId,
  });

  Future<NotificationScheduleResult> scheduleAt({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    String channelId,
  });

  /// 显示/更新一条**常驻倒计时**通知（番茄钟运行时挂在通知栏）。
  ///
  /// 用系统 chronometer 倒计时（[endsAt] 是结束时刻），App 不用每秒刷新 ——
  /// 只在开始 / 暂停 / 恢复时调一次。到点会由另一条提醒通知兜底。
  ///
  /// **固定走静默渠道**，不接受 channelId：倒计时通知会被兜底重发（每 30 秒）
  /// 和划掉后重发，若允许调用方传高重要性渠道，每次重发都会再响一声。
  /// 响铃是"到点提醒"的专属。
  Future<void> showCountdown({
    required int id,
    required String title,
    required String body,
    required DateTime endsAt,
  });

  Future<void> cancel(int id);
}

/// 本地通知的唯一入口：即时通知、定时提醒、取消。
///
/// 存在理由：番茄钟要"到点提醒"，清单模式/其他插件也想用同一套能力。
/// 与其每个功能各自 initialize 一遍，不如收成一个服务 —— 渠道、权限、
/// 精确闹钟降级只在这里处理一次。
///
/// **只做本地通知**：不联网、不推送、不需要任何服务器（与项目"零持续费用"一致）。
class LocalNotificationService implements NotificationSink {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  /// 番茄钟渠道：到点了要能叫醒人，重要性高、带声音。
  static const String channelPomodoro = 'pomodoro';

  /// 番茄钟**倒计时**渠道：静默常驻，不响铃、不震动，只显示状态栏图标和倒计时。
  ///
  /// 必须和 [channelPomodoro] 分开：倒计时通知每 30 秒兜底重发一次，
  /// 如果复用那个高重要性渠道，每次重发都会响一声 —— 划掉再重发就更响。
  /// 响铃是"到点提醒"的事，倒计时只负责"安静地显示还剩多久"。
  static const String channelPomodoroCountdown = 'pomodoro_quiet';

  // 这个 id 换过两次：'pomodoro_countdown' → 'pomodoro_progress' → 'pomodoro_quiet'。
  // Android 的渠道声音/重要性在**首次创建时锁定**，改参数不会覆盖已存在的渠道 ——
  // 前两版分别以"有声音"和"default importance（在部分 OEM 上仍会响）"创建过，
  // 只能继续换 id 才能拿到"绝对静音"这个初始状态。

  /// 插件渠道：默认低打扰，可被系统折叠。
  static const String channelPlugin = 'plugin';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // 项目只做 Android；这个字段是包要求的占位，不会被使用。
        iOS: DarwinInitializationSettings(),
      ),
    );
    _initialized = true;
  }

  /// 申请通知权限（Android 13+ 需要）。已经授权过时直接返回 true。
  ///
  /// **返回 false 不代表失败**：用户可以之后再允许，调用方据此决定要不要提示。
  Future<bool> requestPermission() async {
    await _ensureInitialized();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission();
    return granted ?? true;
  }

  /// 立刻发一条。
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String channelId = channelPlugin,
  }) async {
    await _ensureInitialized();
    try {
      await _plugin.show(id, title, body, _detailsFor(channelId));
    } catch (error, stack) {
      // 通知发不出去不该影响主流程（番茄钟到点仍要结算），但必须留痕。
      AppLogger.warn('LocalNotification', '即时通知失败 id=$id', error, stack);
    }
  }

  /// 在 [at] 提醒一次。
  ///
  /// 走 `zonedSchedule`（AlarmManager）：**进程被杀、App 没在跑，到点照样响**，
  /// 这也是番茄钟不做了前台服务的底气。
  ///
  /// 不精确降级的原因：Android 13+ 的精确闹钟是特殊权限，用户可以关。
  /// 关掉之后不是"不响"，而是"可能晚几分钟"——这种情况下照实返回
  /// [NotificationScheduleResult.inexact]，让界面能提醒用户去开权限，
  /// 而不是让用户以为一切正常。
  Future<NotificationScheduleResult> scheduleAt({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    String channelId = channelPlugin,
  }) async {
    await _ensureInitialized();

    final delay = at.difference(DateTime.now());
    if (delay <= Duration.zero) {
      // 已经过点了：立刻发，别排一个永远不会响的闹钟。
      await show(id: id, title: title, body: body, channelId: channelId);
      return NotificationScheduleResult.exact;
    }

    // 用"现在 + 相对时长"而不是把墙上时间塞进某个时区：
    // 我们只关心"多久之后响"，这样不依赖设备时区库是否初始化正确。
    final when = tz.TZDateTime.now(tz.local).add(delay);
    final details = _detailsFor(channelId);

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      return NotificationScheduleResult.exact;
    } on PlatformException catch (error, stack) {
      AppLogger.warn('LocalNotification', '精确闹钟排期失败，降级为不精确 id=$id', error, stack);
      try {
        await _plugin.zonedSchedule(
          id,
          title,
          body,
          when,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
        return NotificationScheduleResult.inexact;
      } catch (again, stackAgain) {
        AppLogger.warn('LocalNotification', '不精确闹钟也排不上 id=$id', again, stackAgain);
        return NotificationScheduleResult.failed;
      }
    } catch (error, stack) {
      AppLogger.warn('LocalNotification', '排期异常 id=$id', error, stack);
      return NotificationScheduleResult.failed;
    }
  }

  @override
  Future<void> showCountdown({
    required int id,
    required String title,
    required String body,
    required DateTime endsAt,
  }) async {
    await _ensureInitialized();
    // 常驻通知：低打扰、不响铃（already onlyAlertOnce），用户下拉通知栏
    // 就能看到系统自维护的倒计时。App 不刷秒，省电也不触发通知频率限制。
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        // 用**独立静默渠道**，不用调用方传进来的高重要性渠道：
        // default importance 不响铃、不震动，但保留状态栏图标（用户能看到
        // 有个倒计时在跑）。这样 30 秒一次的兜底重发、划掉后的重发，都不会
        // 再冒一次音效 —— 响铃是"到点提醒"那条通知的专属。
        channelPomodoroCountdown,
        '番茄钟倒计时',
        channelDescription: '运行中的专注/休息倒计时',
        // **low 才绝对静音**：default 在部分 OEM 上即使 playSound=false 仍会响，
        // 用户真机上就撞到过（每 7 秒一次兜底重发 = 每 7 秒一声）。
        // 代价是状态栏没有小图标，只在通知抽屉里可见 —— 用户确认可以接受。
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        // 兜底重发是同 id 更新：没有这个标志，每次更新都会再提醒一次。
        // 上一版改静音时把它漏掉了，注释却还写着"already onlyAlertOnce"。
        onlyAlertOnce: true,
        ongoing: true,
        showWhen: true,
        when: endsAt.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
        category: AndroidNotificationCategory.progress,
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(id, title, body, details);
    } catch (error, stack) {
      // 倒计时通知发不出去不该阻断计时，但必须留痕。
      AppLogger.warn('LocalNotification', '倒计时通知失败 id=$id', error, stack);
    }
  }

  Future<void> cancel(int id) async {
    await _ensureInitialized();
    try {
      await _plugin.cancel(id);
    } catch (error, stack) {
      AppLogger.warn('LocalNotification', '取消失败 id=$id', error, stack);
    }
  }

  NotificationDetails _detailsFor(String channelId) {
    switch (channelId) {
      case channelPomodoro:
        return const NotificationDetails(
          android: AndroidNotificationDetails(
            channelPomodoro,
            '番茄钟',
            channelDescription: '专注/休息到点提醒',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
          ),
          iOS: DarwinNotificationDetails(),
        );
      case channelPlugin:
      default:
        return const NotificationDetails(
          android: AndroidNotificationDetails(
            channelPlugin,
            '插件提醒',
            channelDescription: '插件发来的本地提醒',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        );
    }
  }

  /// 测试用：把初始化状态清掉（不为生产路径服务）。
  @visibleForTesting
  void debugReset() {
    _initialized = false;
  }
}
