import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/state/pomodoro_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/services/local_notification_service.dart';
import 'package:v5_app/core/services/pomodoro_timer.dart';

/// 会话管理的测试：**重点是"进程不在了"这种情况**。
///
/// 计时本身的边界在 `pomodoro_timer_test.dart` 里锁死了；这里要证明的是
/// 墙上时间被正确补进有效时长、结束事件只发一次、状态能被读回来。
class _Recorder implements HookListener {
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];

  @override
  String get pluginId => 'test';

  @override
  Set<HookId> get hooks => <HookId>{HookId.pomodoroSessionFinished};

  @override
  Future<void> onEvent(HookEvent event) async => payloads.add(event.payload);
}

class _FakeSink implements NotificationSink {
  final List<String> calls = <String>[];
  final List<DateTime> scheduledAt = <DateTime>[];
  final List<int> cancelledIds = <int>[];
  // 只数"到点提醒"的取消次数：倒计时通知是另一条，别混进来。
  int cancelCount = 0;
  bool permissionGranted = true;
  int countdownCount = 0;
  DateTime? countdownEndsAt;

  @override
  Future<bool> requestPermission() async {
    calls.add('requestPermission');
    return permissionGranted;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String channelId = 'plugin',
  }) async {
    calls.add('show');
  }

  @override
  Future<NotificationScheduleResult> scheduleAt({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    String channelId = 'plugin',
  }) async {
    calls.add('schedule');
    scheduledAt.add(at);
    return permissionGranted
        ? NotificationScheduleResult.exact
        : NotificationScheduleResult.denied;
  }

  @override
  Future<void> showCountdown({
    required int id,
    required String title,
    required String body,
    required DateTime endsAt,
  }) async {
    calls.add('countdown');
    countdownCount++;
    countdownEndsAt = endsAt;
  }

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel');
    cancelledIds.add(id);
    if (id == PomodoroStore.notificationId) cancelCount++;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late Database db;
  late SettingsRepository settings;
  late _Recorder recorder;
  late DateTime fakeNow;

  late _FakeSink sink;

  PomodoroStore build() {
    final store = PomodoroStore(
      settings: settings,
      now: () => fakeNow,
      notifications: sink,
    );
    addTearDown(store.dispose);
    return store;
  }

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    settings = SettingsRepository(db);
    recorder = _Recorder();
    HookBus.instance.clear();
    HookBus.instance.register(recorder);
    fakeNow = DateTime(2026, 11, 1, 9, 0);
    sink = _FakeSink();
  });

  tearDown(() async {
    HookBus.instance.clear();
    await db.close();
  });

  test('开始后进入运行态，状态落库', () async {
    final store = build();
    await store.start();

    expect(store.running, isTrue);
    expect(store.session!.planned, const Duration(minutes: 25));
    expect(store.stateJson!['remainingSeconds'], 1500);

    final saved = await settings.get(SettingsKeys.pomodoroSession);
    expect(saved, isNotNull);
    expect(jsonDecode(saved!)['running'], isTrue);
  });

  test('时间往前走，剩余时间跟着少', () async {
    final store = build();
    await store.start();

    fakeNow = fakeNow.add(const Duration(minutes: 10));
    await store.debugPump();

    expect(store.session!.remaining, const Duration(minutes: 15));
    expect(store.stateJson!['remainingSeconds'], 900);
  });

  test('暂停后不再累计，继续后接着算', () async {
    final store = build();
    await store.start();

    fakeNow = fakeNow.add(const Duration(minutes: 5));
    await store.debugPump();
    await store.pause();
    expect(store.running, isFalse);

    // 暂停期间过了 20 分钟，不应该算进专注
    fakeNow = fakeNow.add(const Duration(minutes: 20));
    await store.debugPump();
    expect(store.session!.elapsed, const Duration(minutes: 5));

    await store.resume();
    fakeNow = fakeNow.add(const Duration(minutes: 3));
    await store.debugPump();
    expect(store.session!.elapsed, const Duration(minutes: 8));
  });

  test('到点结算：停表、派发一次事件、只发一次', () async {
    final store = build();
    await store.start();

    fakeNow = fakeNow.add(const Duration(minutes: 25));
    await store.debugPump();

    expect(store.session!.finished, isTrue);
    expect(store.running, isFalse, reason: '到点后不能还显示在跑');
    expect(recorder.payloads, hasLength(1));
    expect(recorder.payloads.single['mode'], 'focus');
    expect(recorder.payloads.single['actualSeconds'], 1500);

    // 再推一次：已结算的会话不该重复派发（否则插件重复计分）
    await store.debugPump();
    expect(recorder.payloads, hasLength(1));
  });

  test('提前结束（skip）也算一次会话，实际时长如实上报', () async {
    final store = build();
    await store.start();

    fakeNow = fakeNow.add(const Duration(minutes: 7));
    await store.skip();

    expect(recorder.payloads, hasLength(1));
    expect(recorder.payloads.single['actualSeconds'], 420);
    expect(recorder.payloads.single['durationSeconds'], 1500);

    // 跳过之后要能往前：进下一阶段、不自动跑，而不是停在"已结束"
    expect(store.session!.phase, PomodoroPhase.shortBreak);
    expect(store.session!.remaining, store.session!.planned, reason: '新一轮应该是满的');
    expect(store.running, isFalse);
  });

  test('冷启动恢复：不在前台的那段时间要补进去', () async {
    // 模拟"10 分钟前开始的一轮，进程被杀，现在重新打开"
    await settings.set(
      SettingsKeys.pomodoroSession,
      jsonEncode(<String, Object?>{
        'phase': 'focus',
        'plannedSeconds': 1500,
        'elapsedSeconds': 0,
        'running': true,
        'round': 0,
        'sessionId': 's-restore',
        'runningSince': fakeNow.subtract(const Duration(minutes: 10)).toIso8601String(),
      }),
    );

    final store = build();
    await store.load();

    expect(store.session!.elapsed, const Duration(minutes: 10));
    expect(store.session!.remaining, const Duration(minutes: 15));
    expect(store.running, isTrue, reason: '还在计划时长内，应该继续跑');
    expect(recorder.payloads, isEmpty);
  });

  test('冷启动时已经过期：直接结算并派发', () async {
    await settings.set(
      SettingsKeys.pomodoroSession,
      jsonEncode(<String, Object?>{
        'phase': 'focus',
        'plannedSeconds': 1500,
        'elapsedSeconds': 0,
        'running': true,
        'round': 0,
        'sessionId': 's-late',
        'runningSince': fakeNow.subtract(const Duration(hours: 2)).toIso8601String(),
      }),
    );

    final store = build();
    await store.load();

    expect(store.session!.finished, isTrue);
    expect(recorder.payloads, hasLength(1));
    expect(recorder.payloads.single['sessionId'], 's-late');
    expect(recorder.payloads.single['actualSeconds'], 1500, reason: '超时也按计划时长封顶');
  });

  test('重置：清零且不派发事件', () async {
    final store = build();
    await store.start();
    fakeNow = fakeNow.add(const Duration(minutes: 5));
    await store.debugPump();

    await store.reset();

    expect(store.session!.elapsed, Duration.zero);
    expect(store.running, isFalse);
    expect(recorder.payloads, isEmpty, reason: '重置不是完成，不该发奖励事件');
  });

  test('进入下一阶段：短休，且不自动开跑', () async {
    final store = build();
    await store.start();
    fakeNow = fakeNow.add(const Duration(minutes: 25));
    await store.debugPump();

    await store.advance();

    expect(store.session!.phase, PomodoroPhase.shortBreak);
    expect(store.session!.planned, const Duration(minutes: 5));
    expect(store.running, isFalse, reason: '休息要用户自己点开始');

    // 新一轮可以再结算一次
    await store.start(mode: PomodoroPhase.shortBreak);
    fakeNow = fakeNow.add(const Duration(minutes: 5));
    await store.debugPump();
    expect(recorder.payloads, hasLength(2));
  });

  test('timer.next：推进轮次并立刻开跑（轮次不能丢）', () async {
    final store = build();
    await store.start();
    fakeNow = fakeNow.add(const Duration(minutes: 25));
    await store.debugPump();
    expect(store.session!.round, 0);

    await store.next();

    expect(store.session!.phase, PomodoroPhase.shortBreak);
    expect(store.session!.round, 1, reason: '轮次必须推进，否则第 4 轮永远进不了长休');
    expect(store.running, isTrue, reason: 'next 的语义就是"开始休息"，不用再点一次');
  });

  test('开始计时会申请权限并排一条提醒（装配漏接线就抓得住）', () async {
    final store = build();
    await store.start();

    expect(sink.calls, contains('requestPermission'), reason: 'Android 13+ 必须申请，否则通知被静默丢弃');
    expect(sink.calls, contains('schedule'));
    expect(sink.scheduledAt.single.difference(fakeNow), store.session!.planned,
        reason: '应按这一轮的时长排，而不是一个写死的时刻');
    expect(store.canNotify, isTrue);
  });

  test('暂停时取消提醒，继续时重排', () async {
    final store = build();
    await store.start();
    sink.calls.clear();

    await store.pause();
    expect(sink.cancelCount, 1);

    await store.resume();
    expect(sink.calls, contains('schedule'), reason: '继续之后必须重新排，否则这一轮没有提醒');
  });

  test('自然到点不取消提醒（那条通知就是提醒本身）', () async {
    final store = build();
    await store.start();
    final before = sink.cancelCount;

    fakeNow = fakeNow.add(store.session!.planned);
    await store.debugPump();

    expect(store.session!.finished, isTrue);
    expect(sink.cancelCount, before, reason: '到点时取消，会把闹钟刚弹的通知一起抹掉');
  });

  test('提前结束（skip）必须取消提醒，否则过点还会响一次', () async {
    final store = build();
    await store.start();
    final before = sink.cancelCount;

    await store.skip();

    expect(sink.cancelCount, before + 1);
  });

  group('通知栏倒计时（常驻通知）', () {
    test('开始后发一条倒计时通知，结束时间 = now + remaining', () async {
      final store = build();
      await store.start();

      expect(sink.countdownCount, 1);
      final expected = fakeNow.add(store.session!.remaining);
      expect(sink.countdownEndsAt, expected);
    });

    test('暂停取消倒计时，继续重发', () async {
      final store = build();
      await store.start();
      final before = sink.countdownCount;

      await store.pause();
      expect(sink.cancelledIds, contains(PomodoroStore.ongoingNotificationId),
          reason: '暂停了倒计时通知还挂着，就是在骗人');

      await store.resume();
      expect(sink.countdownCount, before + 1, reason: '继续之后要重新挂倒计时');
    });

    test('倒计时通知被划掉后，7 秒内自动重发', () async {
      final store = build();
      await store.start();
      expect(sink.countdownCount, 1);

      // 用户划掉通知 → 时间走过 8 秒 → tick 兜底重发
      fakeNow = fakeNow.add(const Duration(seconds: 8));
      await store.debugPump();

      expect(sink.countdownCount, 2, reason: '划掉了要能自己回来，不能靠用户再开 App');
    });

    test('自然到点：倒计时撤掉，到点提醒留着', () async {
      final store = build();
      await store.start();
      sink.cancelledIds.clear();

      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();

      expect(sink.cancelledIds, contains(PomodoroStore.ongoingNotificationId),
          reason: '计时停了，倒计时通知要撤');
      expect(sink.cancelledIds, isNot(contains(PomodoroStore.notificationId)),
          reason: '到点提醒不能撤，那条就是刚弹出来的提醒');
    });
  });

  test('没有通知权限时：不排提醒，并把 canNotify=false 交给界面', () async {
    sink.permissionGranted = false;
    final store = build();
    await store.start();

    expect(store.canNotify, isFalse);
    expect(sink.calls, isNot(contains('schedule')), reason: '排了也不会显示，不要制造"一切正常"的假象');
    expect(store.stateJson!['canNotify'], isFalse);
  });

  group('历史（timer.history 的数据源）', () {
    test('结算后写进历史，且最近的在前', () async {
      final store = build();
      await store.start();
      final focus = store.session!.planned;
      fakeNow = fakeNow.add(focus);
      await store.debugPump();
      await store.next();

      final shortBreak = store.session!.planned;
      fakeNow = fakeNow.add(shortBreak);
      await store.debugPump();

      final rows = store.history();
      expect(rows, hasLength(2));
      expect(rows.first['mode'], 'short_break', reason: '最近一条在前');
      expect(rows.last['mode'], 'focus');
      expect(rows.first['actualSeconds'], shortBreak.inSeconds);
    });

    test('历史落盘，换一个 store 也读得到（进程重开的场景）', () async {
      final first = build();
      await first.start();
      final planned = first.session!.planned;
      fakeNow = fakeNow.add(planned);
      await first.debugPump();
      final id = first.session!.sessionId;

      // 换实例：模拟进程被杀后重开
      final second = build();
      await second.load();

      final rows = second.history();
      expect(rows, hasLength(1));
      expect(rows.single['sessionId'], id);
      expect(rows.single['actualSeconds'], planned.inSeconds);
    });

    test('同一个会话不会记两条', () async {
      final store = build();
      await store.start();
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();

      // 再推进几次、反复 load 同一份状态，历史都不该变长
      await store.debugPump();
      final reloaded = build();
      await reloaded.load();

      expect(store.history(), hasLength(1));
      expect(reloaded.history(), hasLength(1));
    });

    test('since 只取区间内的，limit 封顶', () async {
      final store = build();
      await store.start();
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();

      final cutoff = fakeNow.subtract(const Duration(minutes: 1));
      expect(store.history(since: cutoff), hasLength(1));
      expect(store.history(since: fakeNow.add(const Duration(minutes: 1))), isEmpty);

      await store.next();
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();
      expect(store.history(limit: 1), hasLength(1));
      expect(store.history(limit: 1).single['mode'], 'short_break');
    });

    test('超过上限时丢最旧的（不能无限长）', () async {
      final store = build();
      // 直接往设置里塞 205 条，看读回来会不会截断到上限
      await settings.set(
        SettingsKeys.pomodoroHistory,
        jsonEncode(List<Map<String, Object?>>.generate(
          PomodoroStore.historyLimit + 5,
          (i) => <String, Object?>{
            'sessionId': 'old-$i',
            'mode': 'focus',
            'durationSeconds': 60,
            'actualSeconds': 60,
            'endedAt': DateTime(2026, 10, 1, 0, i % 60).toUtc().toIso8601String(),
          },
        )),
      );

      final reloaded = build();
      await reloaded.load();
      await reloaded.start();
      fakeNow = fakeNow.add(reloaded.session!.planned);
      await reloaded.debugPump();

      expect(reloaded.history(limit: PomodoroStore.historyLimit),
          hasLength(PomodoroStore.historyLimit));
      expect(reloaded.history().first['sessionId'], isNot(startsWith('old-')));
    });

    test('历史里存的是 UTC 时间（插件按本地日期过滤才准）', () async {
      final store = build();
      await store.start();
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();

      final endedAt = store.history().single['endedAt'] as String;
      expect(endedAt.endsWith('Z'), isTrue, reason: '必须是 UTC，带 Z');
    });
  });

  group('专注时长（预设 5~60）', () {
    test('传 focusMinutes 就按它建这一轮', () async {
      final store = build();
      await store.start(focusMinutes: 45);
      expect(store.session!.planned, const Duration(minutes: 45));
      expect(store.stateJson!['plannedSeconds'], 2700);
    });

    test('configure 在空闲时立刻改掉时长，并换 id', () async {
      final store = build();
      await store.start();
      await store.pause(); // 一秒没跑过就暂停：空闲且 elapsed 为 0
      final before = store.session!.sessionId;

      final ok = await store.configure(focusMinutes: 45);

      expect(ok, isTrue);
      expect(store.session!.planned, const Duration(minutes: 45),
          reason: '圆环要立刻变，不能等下一轮');
      expect(store.session!.sessionId, isNot(before), reason: '旧 id 那条已经作废');
      expect(store.session!.elapsed, Duration.zero);
    });

    test('已经开跑时改：本轮不变，留给下一次', () async {
      final store = build();
      await store.start();
      final before = store.session!.planned;

      // 跑了几秒再改
      fakeNow = fakeNow.add(const Duration(seconds: 30));
      await store.debugPump();

      expect(await store.configure(focusMinutes: 45), isFalse,
          reason: 'false = 这一轮不重建，改动留给下一轮');
      expect(store.session!.planned, before, reason: '本轮不能凭空加减时间');

      // 下一次开始就该是新时长
      await store.reset();
      await store.start();
      expect(store.session!.planned, const Duration(minutes: 45));
    });

    test('重置后按当前节奏重建（旧会话的时长不能赖着）', () async {
      final store = build();
      await store.start(focusMinutes: 20);
      expect(store.session!.planned, const Duration(minutes: 20));

      // 换成 45 分钟，再重置
      await store.configure(focusMinutes: 45);
      await store.start();
      await store.reset();

      expect(store.session!.planned, const Duration(minutes: 45),
          reason: '重置要用当前节奏，不是会话里那个旧数字');
      expect(store.session!.elapsed, Duration.zero);
    });

    test('专注和休息一起改（联动）', () async {
      final store = build();
      await store.configure(
        focusMinutes: 45,
        shortBreakMinutes: 10,
        longBreakMinutes: 30,
      );
      await store.start();
      expect(store.session!.planned, const Duration(minutes: 45));

      fakeNow = fakeNow.add(const Duration(minutes: 45));
      await store.debugPump();
      await store.next();

      expect(store.session!.phase, PomodoroPhase.shortBreak);
      expect(store.session!.planned, const Duration(minutes: 10),
          reason: '短休要跟着专注一起改，不能还是 5 分钟');
    });

    test('改了之后下一轮专注也沿用（不能变回 25）', () async {
      final store = build();
      await store.configure(focusMinutes: 45);
      await store.start();
      expect(store.session!.planned, const Duration(minutes: 45));

      fakeNow = fakeNow.add(const Duration(minutes: 45));
      await store.debugPump();
      await store.next(); // 进短休
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();
      await store.next(); // 回到专注

      expect(store.session!.planned, const Duration(minutes: 45),
          reason: 'plan 要在 store 里留住，不能每轮回到默认');
    });
  });

  group('会话 id（历史去重靠它，不能撞）', () {
    test('重置后再跑一轮，算新会话（不会被去重吃掉）', () async {
      final store = build();
      await store.start();
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();
      expect(store.history(), hasLength(1));

      await store.reset();
      // 走"继续"这条路（插件旧版本就是这样调的）—— 主包必须自己兜住：
      final before = store.session!.sessionId;
      await store.resume();
      expect(store.session!.sessionId, isNot(before),
          reason: '一秒没跑过的继续应该是新会话');

      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();
      expect(store.history(), hasLength(2), reason: '第二轮必须记上，不能被去重丢掉');
    });

    test('暂停后继续是同一会话（不能拆成两条）', () async {
      final store = build();
      await store.start();
      final id = store.session!.sessionId;
      final half = Duration(seconds: store.session!.planned.inSeconds ~/ 2);

      fakeNow = fakeNow.add(half);
      await store.debugPump();
      await store.pause();
      await store.resume();

      expect(store.session!.sessionId, id);
      expect(store.session!.elapsed, half, reason: '继续不能把已跑的时间抹掉');

      fakeNow = fakeNow.add(store.session!.planned - half);
      await store.debugPump();
      expect(store.history(), hasLength(1), reason: '一次专注只记一条');
    });

    test('进入下一阶段后是新会话', () async {
      final store = build();
      await store.start();
      final first = store.session!.sessionId;
      fakeNow = fakeNow.add(store.session!.planned);
      await store.debugPump();
      await store.next();

      expect(store.session!.sessionId, isNot(first));
    });
  });

  test('没有会话时 stateJson 是 null（插件据此画空态）', () {
    expect(build().stateJson, isNull);
  });
}
