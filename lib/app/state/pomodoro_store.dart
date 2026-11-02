import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/extension/extension_hook.dart';
import '../../core/services/local_notification_service.dart';
import '../../core/services/pomodoro_timer.dart';
import '../data/settings_repository.dart';

/// 番茄钟的会话管理：**主包提供的能力，不是主包的界面**。
///
/// 它管事的三件东西：
/// 1. 当前会话（[PomodoroTimer] 状态机 + 墙上时间）；
/// 2. 到点提醒（交给 [LocalNotificationService] 排精确闹钟）；
/// 3. 到点后的 `pomodoro.sessionFinished` 事件（走 [HookBus]，插件按 sessionId 幂等）。
///
/// **为什么墙上时间在这里而不在状态机里**：状态机要保持可测（不认时钟），
/// 而"跑了多久"必须由真实时间决定 —— 进程被杀再回来时，靠 `runningSince`
/// 把中间那段时间补上，否则用户关了 App 再打开会发现计时"停住了"。
class PomodoroStore extends ChangeNotifier {
  PomodoroStore({
    required SettingsRepository settings,
    HookBus? hooks,
    LocalNotificationService? notifications,
    DateTime Function()? now,
    Duration tickInterval = const Duration(seconds: 1),
  })  : _settings = settings,
        _hooks = hooks ?? HookBus.instance,
        _notifications = notifications,
        _now = now ?? DateTime.now,
        _tickInterval = tickInterval;

  /// 通知 id。避开更新器的 0x7605 / 0x7606，出问题好一眼区分。
  static const int notificationId = 0x7071;

  final SettingsRepository _settings;
  final HookBus _hooks;
  final LocalNotificationService? _notifications;
  final DateTime Function() _now;
  final Duration _tickInterval;

  /// 专注时长（秒）。发布构建是 25 分钟；验收时用
  /// `--dart-define=POMODORO_FOCUS_SECONDS=60` 打一个 1 分钟的包，
  /// 用来真实验证"到点闹钟会不会响" —— 等 25 分钟不现实，但机制必须验。
  static const int focusSeconds =
      int.fromEnvironment('POMODORO_FOCUS_SECONDS', defaultValue: 25 * 60);

  PomodoroPlan _plan = PomodoroPlan(focus: Duration(seconds: focusSeconds));
  PomodoroTimer? _session;
  DateTime? _runningSince;
  Timer? _ticker;

  /// 已经为哪个 session 派发过结束事件。**同一个会话只发一次** ——
  /// tick、冷启动恢复、用户手动 skip 三条路都可能走到结算，去重必须靠它，
  /// 否则插件会收到重复的奖励事件。
  String? _settledSessionId;

  PomodoroPlan get plan => _plan;

  PomodoroTimer? get session => _session;

  bool get running => _session?.running ?? false;

  /// 冷启动恢复：读出上次的会话，把"不在前台的那段时间"补进有效时长。
  ///
  /// 补的时候**只看墙上时间**，不假设进程一直在跑。已经超过计划时长的，
  /// 直接结算 —— 用户回来看到的是"这一轮早就结束了"，而不是一个停在 24:59 的假象。
  Future<void> load() async {
    final raw = await _settings.get(SettingsKeys.pomodoroSession);
    if (raw == null || raw.isEmpty) return;

    Map<String, Object?> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      json = Map<String, Object?>.from(decoded);
    } catch (error, stack) {
      // 一条读不懂的状态不该让 App 起不来，也不该继续拿它算时间。
      debugPrint('[pomodoro] 会话状态解析失败，按没有会话处理：$error');
      assert(() {
        debugPrintStack(stackTrace: stack);
        return true;
      }());
      return;
    }

    final restored = PomodoroTimer.tryFromJson(json);
    if (restored == null) return;

    _session = restored;
    _settledSessionId = _settledSessionId; // 保持原值（首次为 null）

    final sinceRaw = json['runningSince'];
    if (restored.running && sinceRaw is String) {
      final since = DateTime.tryParse(sinceRaw);
      if (since != null) {
        _runningSince = since;
        final away = _now().difference(since);
        if (away > Duration.zero) {
          _session = restored.tick(away);
        }
      } else {
        // 有时间戳但读不懂：不要凭空累加，但也不能装作在跑
        _session = restored.pause();
      }
    }

    if (_session!.finished) {
      await _settle();
    } else {
      if (_session!.running) {
        _startTicker();
        await _scheduleNotification();
      }
      notifyListeners();
    }
  }

  /// 开始一轮。[mode] 缺省专注。
  Future<void> start({PomodoroPhase mode = PomodoroPhase.focus, int? taskId}) async {
    _stopTicker();
    _settledSessionId = null;
    _session = PomodoroTimer.start(
      _plan,
      phase: mode,
      round: _session?.round ?? 0,
      sessionId: _newSessionId(),
      taskId: taskId,
    );
    _runningSince = _now();
    _startTicker();
    await _scheduleNotification();
    await _persist();
    notifyListeners();
  }

  Future<void> pause() async {
    final current = _session;
    if (current == null || !current.running) return;

    _session = _accumulate().pause();
    _runningSince = null;
    _stopTicker();
    await _cancelNotification();
    await _persist();
    notifyListeners();
  }

  Future<void> resume() async {
    final current = _session;
    if (current == null || current.running || current.finished) return;

    _session = current.resume();
    _runningSince = _now();
    _startTicker();
    await _scheduleNotification();
    await _persist();
    notifyListeners();
  }

  Future<void> reset() async {
    final current = _session;
    if (current == null) return;

    _stopTicker();
    _settledSessionId = null;
    _session = current.reset(running: false);
    _runningSince = null;
    await _cancelNotification();
    await _persist();
    notifyListeners();
  }

  /// 提前结束这一轮：照常结算并派发事件（用户主动结束也算一次会话）。
  Future<void> skip() async {
    final current = _session;
    if (current == null) return;
    _session = _accumulate();
    await _settle();
  }

  /// 进入下一阶段（专注→休息 / 休息→专注）。**不自动开跑**，等用户点。
  Future<void> advance() async {
    final current = _session;
    if (current == null) return;
    _session = current.advance(_plan);
    _runningSince = null;
    _settledSessionId = null;
    _stopTicker();
    await _cancelNotification();
    await _persist();
    notifyListeners();
  }

  /// 进入下一阶段并**立刻开跑**。
  ///
  /// 和 [advance] 的区别是"谁来按下开始"：`advance` 只换阶段（用户可能想先歇会儿
  /// 再开始），`next` 是用户在"已结束"状态下点了"开始休息" —— 那一下就是让他跑。
  /// 两件事拆开是因为轮次推进和开始计时是两个语义，合在插件里做会让插件自己
  /// 维护 round，早晚和主包对不上。
  Future<void> next() async {
    final current = _session;
    if (current == null) return;
    final advanced = current.advance(_plan);
    // **先落盘再 start**：start 读的是 `_session?.round`，
    // 不先把推进后的状态放回去，轮次会停在上一个值 —— 第 4 个专注之后
    // 永远进不了长休，而且表面上一切正常。
    _session = advanced;
    _settledSessionId = null;
    await start(mode: advanced.phase, taskId: advanced.taskId);
  }

  /// 给 bridge 用的状态快照。没有会话时返回 null。
  Map<String, Object?>? get stateJson {
    final current = _session;
    if (current == null) return null;
    return <String, Object?>{
      'sessionId': current.sessionId,
      'mode': current.phase.id,
      'running': current.running,
      'finished': current.finished,
      'round': current.round,
      'plannedSeconds': current.planned.inSeconds,
      'remainingSeconds': current.remaining.inSeconds,
      'progress': current.progress,
      if (current.taskId != null) 'taskId': current.taskId,
    };
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }

  // ---- 内部 ----

  /// 把"自上次记账以来经过的时间"并进 elapsed。
  PomodoroTimer _accumulate() {
    final current = _session!;
    final since = _runningSince;
    if (!current.running || since == null) return current;
    final delta = _now().difference(since);
    if (delta <= Duration.zero) return current;
    _runningSince = _now();
    return current.tick(delta);
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (_) => unawaited(_onTick()));
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _onTick() async {
    final current = _session;
    if (current == null || !current.running) return;
    final next = _accumulate();
    if (identical(next, current)) return;
    _session = next;
    if (next.finished) {
      await _settle();
    } else {
      notifyListeners();
    }
  }

  /// 测试用：立刻走一次 tick，不依赖真实定时器与事件循环等待。
  @visibleForTesting
  Future<void> debugPump() => _onTick();

  /// 结算：停表、取消提醒、派发事件、落一条"已完成"的状态。
  Future<void> _settle() async {
    final current = _session;
    if (current == null) return;

    final sessionId = current.sessionId;
    if (sessionId != null && sessionId == _settledSessionId) return;
    _settledSessionId = sessionId;

    _stopTicker();
    _runningSince = null;
    _session = current.copyWith(running: false);
    await _cancelNotification();
    await _persist();

    // **不 await**：钩子是通知不是拦截，插件慢不能拖住结算。
    unawaited(_hooks.emit(
      HookId.pomodoroSessionFinished,
      payload: current.toFinishedPayload(_now()),
    ));
    notifyListeners();
  }

  Future<void> _scheduleNotification() async {
    final current = _session;
    final notifications = _notifications;
    if (current == null || notifications == null) return;
    if (!current.running || current.finished) return;

    final isFocus = current.isFocus;
    final minutes = current.planned.inMinutes;
    final result = await notifications.scheduleAt(
      id: notificationId,
      at: _now().add(current.remaining),
      title: isFocus ? '专注结束' : '休息结束',
      body: isFocus ? '$minutes 分钟到了，歇一会儿' : '休息好了，开始下一轮',
      channelId: LocalNotificationService.channelPomodoro,
    );
    if (result == NotificationScheduleResult.denied ||
        result == NotificationScheduleResult.failed) {
      // 到点不响是用户能感知的失败，必须留痕（界面以后要出提示）。
      debugPrint('[pomodoro] 提醒排期失败：$result');
    }
  }

  Future<void> _cancelNotification() async {
    await _notifications?.cancel(notificationId);
  }

  Future<void> _persist() async {
    final current = _session;
    if (current == null) {
      // 没有 API 级的删除，写空串表示"没有会话"（load 里也按空处理）。
      await _settings.set(SettingsKeys.pomodoroSession, '');
      return;
    }
    await _settings.set(
      SettingsKeys.pomodoroSession,
      jsonEncode(<String, Object?>{
        ...current.toJson(),
        if (current.running && _runningSince != null)
          'runningSince': _runningSince!.toIso8601String(),
      }),
    );
  }

  String _newSessionId() => 'pm-${_now().microsecondsSinceEpoch}';
}
