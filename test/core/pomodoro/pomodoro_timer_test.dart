import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/services/pomodoro_timer.dart';

/// 计时引擎的测试。
///
/// 这个状态机的价值全在"边界"上：暂停到底算不算、多跑的那几分钟算不算、
/// 到点之后还能不能继续。全都是拿假时间喂出来的，不用等 25 分钟。
void main() {
  const plan = PomodoroPlan(
    focus: Duration(minutes: 25),
    shortBreak: Duration(minutes: 5),
    longBreak: Duration(minutes: 15),
    roundsPerLongBreak: 4,
  );

  group('推进与剩余', () {
    test('开始后走一分钟，剩 24 分钟', () {
      final t = PomodoroTimer.start(plan).tick(const Duration(minutes: 1));
      expect(t.remaining, const Duration(minutes: 24));
      expect(t.finished, isFalse);
      expect(t.running, isTrue);
    });

    test('走满 25 分钟就完成，剩下的时间不再累加', () {
      final t = PomodoroTimer.start(plan).tick(const Duration(minutes: 30));
      expect(t.finished, isTrue);
      expect(t.elapsed, const Duration(minutes: 25), reason: '超过终点的部分要截断');
      expect(t.remaining, Duration.zero, reason: '不能出现负数剩余');
      expect(t.progress, 1.0);
    });

    test('完成后再 tick 不变（后台多跑几分钟不影响结算）', () {
      final done = PomodoroTimer.start(plan).tick(const Duration(minutes: 25));
      final again = done.tick(const Duration(minutes: 5));
      expect(again.elapsed, done.elapsed);
    });
  });

  group('暂停与继续', () {
    test('暂停期间不累计有效时长', () {
      final t = PomodoroTimer.start(plan)
          .tick(const Duration(minutes: 5))
          .pause()
          .tick(const Duration(minutes: 10));
      expect(t.elapsed, const Duration(minutes: 5), reason: '暂停的 10 分钟不算专注');
      expect(t.running, isFalse);
    });

    test('继续后接着累计', () {
      final t = PomodoroTimer.start(plan)
          .tick(const Duration(minutes: 5))
          .pause()
          .tick(const Duration(minutes: 10))
          .resume()
          .tick(const Duration(minutes: 3));
      expect(t.elapsed, const Duration(minutes: 8));
    });

    test('完成之后不允许继续', () {
      final done = PomodoroTimer.start(plan).tick(const Duration(minutes: 25));
      expect(done.resume().running, isFalse, reason: '到点就是到点，继续等于把时长拉长');
    });

    test('重置清零并回到运行', () {
      final t = PomodoroTimer.start(plan).tick(const Duration(minutes: 7)).reset();
      expect(t.elapsed, Duration.zero);
      expect(t.running, isTrue);
      expect(t.remaining, const Duration(minutes: 25));
    });

    test('reset(running: false) 只清时长不自动跑', () {
      final t = PomodoroTimer.start(plan).reset(running: false);
      expect(t.elapsed, Duration.zero);
      expect(t.running, isFalse);
    });
  });

  group('阶段推进', () {
    test('专注结束进短休，轮数 +1', () {
      final next = PomodoroTimer.start(plan)
          .tick(const Duration(minutes: 25))
          .advance(plan);
      expect(next.phase, PomodoroPhase.shortBreak);
      expect(next.planned, const Duration(minutes: 5));
      expect(next.round, 1);
      expect(next.running, isFalse, reason: '进下一阶段不自动开跑，等用户点开始');
    });

    test('第 4 个专注结束进长休', () {
      final timer = PomodoroTimer.start(plan, round: 3)
          .tick(const Duration(minutes: 25))
          .advance(plan);
      expect(timer.phase, PomodoroPhase.longBreak);
      expect(timer.planned, const Duration(minutes: 15));
      expect(timer.round, 4);
    });

    test('休息结束回到专注，轮数不变', () {
      final timer = PomodoroTimer.start(plan, phase: PomodoroPhase.shortBreak, round: 2)
          .tick(const Duration(minutes: 5))
          .advance(plan);
      expect(timer.phase, PomodoroPhase.focus);
      expect(timer.round, 2, reason: '轮数只由"完成的专注"决定');
    });

    test('中途提前结束也推进轮数（用户主动结束）', () {
      final timer = PomodoroTimer.start(plan)
          .tick(const Duration(seconds: 30))
          .advance(plan);
      expect(timer.phase, PomodoroPhase.shortBreak);
      expect(timer.round, 1);
    });
  });

  group('结算数据', () {
    test('actualSeconds 用有效时长，不含暂停', () {
      final t = PomodoroTimer.start(plan, sessionId: 's-1', taskId: 42)
          .tick(const Duration(minutes: 10))
          .pause()
          .resume()
          .tick(const Duration(minutes: 5));
      final payload = t.toFinishedPayload(DateTime.utc(2026, 11, 1, 12));

      expect(payload['sessionId'], 's-1');
      expect(payload['mode'], 'focus');
      expect(payload['durationSeconds'], 1500);
      expect(payload['actualSeconds'], 900);
      expect(payload['taskId'], 42);
      expect(payload['endedAt'], '2026-11-01T12:00:00.000Z');
    });

    test('没有任务时不带 taskId 字段', () {
      final payload = PomodoroTimer.start(plan).toFinishedPayload(DateTime.utc(2026));
      expect(payload.containsKey('taskId'), isFalse);
    });
  });

  group('存盘往返', () {
    test('写进去再读出来是同一个状态', () {
      final before = PomodoroTimer.start(plan, sessionId: 's-9', taskId: 7)
          .tick(const Duration(minutes: 12))
          .pause();
      final after = PomodoroTimer.tryFromJson(before.toJson())!;

      expect(after.phase, before.phase);
      expect(after.planned, before.planned);
      expect(after.elapsed, before.elapsed);
      expect(after.running, before.running);
      expect(after.sessionId, 's-9');
      expect(after.taskId, 7);
    });

    test('认不出来就返回 null，不抛（一条坏状态不该让 App 起不来）', () {
      expect(PomodoroTimer.tryFromJson(<String, Object?>{}), isNull);
      expect(PomodoroTimer.tryFromJson(<String, Object?>{'phase': 'nope'}), isNull);
      expect(
        PomodoroTimer.tryFromJson(<String, Object?>{'phase': 'focus', 'plannedSeconds': 0}),
        isNull,
        reason: '计划时长为 0 的状态没有意义',
      );
    });

    test('存盘里的 elapsed 超过 planned 时按 planned 收口', () {
      final t = PomodoroTimer.tryFromJson(<String, Object?>{
        'phase': 'focus',
        'plannedSeconds': 1500,
        'elapsedSeconds': 99999,
        'running': true,
        'round': 1,
      })!;
      expect(t.elapsed, const Duration(minutes: 25));
      expect(t.finished, isTrue);
    });
  });
}
