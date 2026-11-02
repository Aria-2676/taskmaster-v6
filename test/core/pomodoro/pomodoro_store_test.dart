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
  int cancelCount = 0;
  bool permissionGranted = true;

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
  Future<void> cancel(int id) async {
    calls.add('cancel');
    cancelCount++;
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

  test('没有通知权限时：不排提醒，并把 canNotify=false 交给界面', () async {
    sink.permissionGranted = false;
    final store = build();
    await store.start();

    expect(store.canNotify, isFalse);
    expect(sink.calls, isNot(contains('schedule')), reason: '排了也不会显示，不要制造"一切正常"的假象');
    expect(store.stateJson!['canNotify'], isFalse);
  });

  test('没有会话时 stateJson 是 null（插件据此画空态）', () {
    expect(build().stateJson, isNull);
  });
}
