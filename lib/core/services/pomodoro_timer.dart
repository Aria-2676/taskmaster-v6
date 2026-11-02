import 'dart:math' as math;

/// 番茄钟的阶段。
///
/// 只有三种：专注、短休、长休。**没有"待机"阶段** —— 没在计时就是"没有会话"，
/// 用一个额外枚举值表示它会让状态机多出一堆非法组合（待机但有 elapsed？
/// 待机但有 planned？）。
enum PomodoroPhase {
  focus('focus', '专注'),
  shortBreak('short_break', '短休'),
  longBreak('long_break', '长休');

  const PomodoroPhase(this.id, this.label);

  /// 存盘与钩子 payload 用的稳定标识，**不要改**（插件按它分支）。
  final String id;

  /// 界面上显示的中文名。
  final String label;

  bool get isBreak => this != PomodoroPhase.focus;

  static PomodoroPhase? tryParse(String? raw) {
    for (final phase in values) {
      if (phase.id == raw) return phase;
    }
    return null;
  }
}

/// 一轮番茄钟的时长配置。
///
/// 做成值对象而不是常量：以后要能在设置里改（25/5/15 是默认值，不是硬编码），
/// 传进状态机的永远是"这一轮用的配方"。
class PomodoroPlan {
  const PomodoroPlan({
    this.focus = const Duration(minutes: 25),
    this.shortBreak = const Duration(minutes: 5),
    this.longBreak = const Duration(minutes: 15),
    this.roundsPerLongBreak = 4,
  })  : assert(roundsPerLongBreak >= 1, '长休间隔至少 1 轮'),
        assert(roundsPerLongBreak <= 12, '长休间隔太大没有意义');

  final Duration focus;
  final Duration shortBreak;
  final Duration longBreak;

  /// 每几个专注来一次长休。
  final int roundsPerLongBreak;

  Duration durationOf(PomodoroPhase phase) {
    switch (phase) {
      case PomodoroPhase.focus:
        return focus;
      case PomodoroPhase.shortBreak:
        return shortBreak;
      case PomodoroPhase.longBreak:
        return longBreak;
    }
  }

  PomodoroPlan copyWith({
    Duration? focus,
    Duration? shortBreak,
    Duration? longBreak,
    int? roundsPerLongBreak,
  }) {
    return PomodoroPlan(
      focus: focus ?? this.focus,
      shortBreak: shortBreak ?? this.shortBreak,
      longBreak: longBreak ?? this.longBreak,
      roundsPerLongBreak: roundsPerLongBreak ?? this.roundsPerLongBreak,
    );
  }
}

/// 不可变的计时状态机。
///
/// **它不认识时钟。** 时间只通过 [tick] 喂进来 —— 这样可以拿假时间把
/// "暂停不计时""跨终点截断""完成后不再走"全部断言掉，不用等 25 分钟。
/// 谁负责定时器、谁负责通知、谁负责存盘，都不归它管。
///
/// `elapsed` 只累计**有效运行时长**：暂停期间不增，所以"暂停 10 分钟回来
/// 还剩多少"这类问题由调用方决定，而不是被偷偷算进 `actualSeconds`。
class PomodoroTimer {
  const PomodoroTimer({
    required this.phase,
    required this.planned,
    required this.elapsed,
    required this.running,
    required this.round,
    this.sessionId,
    this.taskId,
  });

  /// 新开一个阶段。[round] 是"已经完成的专注数"，从 0 开始。
  factory PomodoroTimer.start(
    PomodoroPlan plan, {
    PomodoroPhase phase = PomodoroPhase.focus,
    int round = 0,
    String? sessionId,
    int? taskId,
  }) {
    return PomodoroTimer(
      phase: phase,
      planned: plan.durationOf(phase),
      elapsed: Duration.zero,
      running: true,
      round: round,
      sessionId: sessionId,
      taskId: taskId,
    );
  }

  final PomodoroPhase phase;

  /// 本轮计划时长（开始那一刻就固定，不随后改配置而变）。
  final Duration planned;

  /// 已累计的有效运行时长（暂停不计）。最大等于 [planned]。
  final Duration elapsed;

  final bool running;

  /// 已完成的专注轮数，用来决定下一次是短休还是长休。
  final int round;

  /// 由主包生成，钩子与插件按它幂等。
  final String? sessionId;

  /// 关联的任务（可选）。番茄钟不强制绑任务。
  final int? taskId;

  Duration get remaining {
    final left = planned - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// 0.0 ~ 1.0，用于画进度。
  double get progress {
    if (planned.inMilliseconds <= 0) return 1;
    return (elapsed.inMilliseconds / planned.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 到点（或超时补齐）。
  bool get finished => elapsed >= planned;

  bool get isFocus => phase == PomodoroPhase.focus;

  /// 推进 [delta]。不在运行中、或已经完成时原样返回。
  ///
  /// 超过终点的部分**截断到 planned**：`actualSeconds` 要等于"实际有效时长"，
  /// 让它在后台多跑三分钟也还是 25:00，不然结算数据会飘。
  ///
  /// 到点的同时把 `running` 置 false：**"完成"和"在跑"不能同时成立**，
  /// 否则界面会显示成 00:00 还在运行，`resume()` 也会变成一个空操作。
  PomodoroTimer tick(Duration delta) {
    if (!running || delta <= Duration.zero || finished) return this;
    final next = elapsed + delta;
    if (next >= planned) {
      return copyWith(elapsed: planned, running: false);
    }
    return copyWith(elapsed: next);
  }

  /// 暂停。**不改变 elapsed** —— 暂停前的有效时长已经攒在那里了。
  PomodoroTimer pause() {
    if (!running || finished) return this;
    return copyWith(running: false);
  }

  /// 继续。[finished] 之后不允许继续，必须 [advance] 或重新开始。
  PomodoroTimer resume() {
    if (running || finished) return this;
    return copyWith(running: true);
  }

  /// 重置当前阶段：时长清零、回到运行状态。
  ///
  /// 用 `reset(running: false)` 表示"重置后先别跑"（例如从设置页改完时长）。
  PomodoroTimer reset({bool running = true}) {
    return copyWith(elapsed: Duration.zero, running: running);
  }

  /// 本阶段结束后进入下一阶段。
  ///
  /// 专注结束 → 第 N 个专注之后是长休（N = [PomodoroPlan.roundsPerLongBreak]），
  /// 其余是短休；休息结束 → 回到专注。
  /// **调用方负责确认已经 [finished]**；未完成时调用按"提前结束"处理，
  /// 这是允许的（用户中途想结束），但轮数照常推进。
  PomodoroTimer advance(PomodoroPlan plan) {
    if (isFocus) {
      final completed = round + 1;
      final isLong = completed % plan.roundsPerLongBreak == 0;
      final next = isLong ? PomodoroPhase.longBreak : PomodoroPhase.shortBreak;
      return PomodoroTimer(
        phase: next,
        planned: plan.durationOf(next),
        elapsed: Duration.zero,
        running: false,
        round: completed,
        taskId: taskId,
      );
    }
    return PomodoroTimer(
      phase: PomodoroPhase.focus,
      planned: plan.durationOf(PomodoroPhase.focus),
      elapsed: Duration.zero,
      running: false,
      round: round,
      taskId: taskId,
    );
  }

  /// 到点那一刻的结算数据。`actualSeconds` 取有效运行时长（已截断）。
  Map<String, Object?> toFinishedPayload(DateTime endedAt) {
    return <String, Object?>{
      'sessionId': sessionId,
      'mode': phase.id,
      'durationSeconds': planned.inSeconds,
      'actualSeconds': math.min(elapsed.inSeconds, planned.inSeconds),
      'endedAt': endedAt.toUtc().toIso8601String(),
      if (taskId != null) 'taskId': taskId,
    };
  }

  /// 存盘形态。**字段名是稳定契约**（老版本读不了新字段，要能降级）。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'phase': phase.id,
      'plannedSeconds': planned.inSeconds,
      'elapsedSeconds': elapsed.inSeconds,
      'running': running,
      'round': round,
      if (sessionId != null) 'sessionId': sessionId,
      if (taskId != null) 'taskId': taskId,
    };
  }

  /// 从存盘形态恢复。**认不出来就返回 null**，由调用方决定"当作没有会话"，
  /// 而不是抛异常 —— 一条坏状态不该让 App 起不来。
  static PomodoroTimer? tryFromJson(Map<String, Object?> json) {
    final phase = PomodoroPhase.tryParse(json['phase'] as String?);
    final planned = _seconds(json['plannedSeconds']);
    final elapsed = _seconds(json['elapsedSeconds']);
    if (phase == null || planned == null || elapsed == null) return null;
    if (planned <= Duration.zero) return null;

    final round = json['round'];
    return PomodoroTimer(
      phase: phase,
      planned: planned,
      elapsed: elapsed > planned ? planned : elapsed,
      running: json['running'] == true,
      round: round is int && round >= 0 ? round : 0,
      sessionId: json['sessionId'] as String?,
      taskId: json['taskId'] is int ? json['taskId']! as int : null,
    );
  }

  static Duration? _seconds(Object? raw) {
    if (raw is int && raw >= 0) return Duration(seconds: raw);
    if (raw is num && raw >= 0) return Duration(seconds: raw.toInt());
    return null;
  }

  PomodoroTimer copyWith({
    PomodoroPhase? phase,
    Duration? planned,
    Duration? elapsed,
    bool? running,
    int? round,
    String? sessionId,
    int? taskId,
  }) {
    return PomodoroTimer(
      phase: phase ?? this.phase,
      planned: planned ?? this.planned,
      elapsed: elapsed ?? this.elapsed,
      running: running ?? this.running,
      round: round ?? this.round,
      sessionId: sessionId ?? this.sessionId,
      taskId: taskId ?? this.taskId,
    );
  }
}
