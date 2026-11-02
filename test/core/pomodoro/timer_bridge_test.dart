import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_bridge.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/state/pomodoro_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';

/// `timer.history` 的接口约定。
///
/// 这条查询是插件拿记录的**唯一途径**（事件只用来触发刷新），
/// 所以它的边界必须钉住：参数写错要明确报错，而不是返回空列表 ——
/// 空列表会被插件画成"今天没有记录"，用户看不出是自己写错了代码。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late Database db;
  late SettingsRepository settings;
  late DateTime fakeNow;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    settings = SettingsRepository(db);
    fakeNow = DateTime(2026, 11, 2, 9);
  });

  tearDown(() async => db.close());

  PomodoroStore buildStore() {
    final store = PomodoroStore(settings: settings, now: () => fakeNow);
    addTearDown(store.dispose);
    return store;
  }

  PluginBridge bridgeWith({PomodoroStore? pomodoro}) => PluginBridge(
        pluginId: 'pomodoro',
        version: '1.2.0',
        permissions: <String>{PluginPermissions.notifyLocal},
        tasks: TaskRepository(db),
        settings: settings,
        contract: PluginContract.current,
        hooks: <HookId>{HookId.pomodoroSessionFinished},
        journal: EventJournal(db),
        pomodoro: pomodoro,
      );

  test('没接线时回 unavailable（老主包不能假装有计时能力）', () async {
    final result = await bridgeWith().dispatch('timer.history', <String, Object?>{});

    expect(result['ok'], isFalse);
    expect((result['error']! as Map)['code'], 'unavailable');
  });

  test('返回已结束的会话，字段与钩子 payload 一致', () async {
    final store = buildStore();
    await store.start();
    fakeNow = fakeNow.add(store.session!.planned);
    await store.debugPump();

    final result = await bridgeWith(pomodoro: store)
        .dispatch('timer.history', <String, Object?>{});

    expect(result['ok'], isTrue);
    final sessions = (result['result']! as Map)['sessions']! as List;
    expect(sessions, hasLength(1));
    final row = sessions.single as Map;
    expect(row['sessionId'], isNotEmpty);
    expect(row['mode'], 'focus');
    expect(row['durationSeconds'], store.session!.planned.inSeconds);
    expect(row['actualSeconds'], store.session!.planned.inSeconds);
    expect(row['endedAt'], endsWith('Z'));
  });

  test('timer.start 带上 focusMinutes 就按它建会话', () async {
    final store = buildStore();
    final result = await bridgeWith(pomodoro: store)
        .dispatch('timer.start', <String, Object?>{'focusMinutes': 45});

    expect(result['ok'], isTrue);
    expect((result['result']! as Map)['plannedSeconds'], 2700);
  });

  test('focusMinutes 越界报错，不能默默用默认值', () async {
    final store = buildStore();
    final bridge = bridgeWith(pomodoro: store);

    for (final bad in <Object>[0, -5, 181, '30']) {
      final result = await bridge.dispatch(
        'timer.start',
        <String, Object?>{'focusMinutes': bad},
      );
      expect(result['ok'], isFalse, reason: 'focusMinutes=$bad 应该被拒');
      expect((result['error']! as Map)['code'], 'bad_params');
    }
  });

  test('timer.configure 空闲时立即生效（applied=now）', () async {
    final store = buildStore();
    final result = await bridgeWith(pomodoro: store).dispatch(
      'timer.configure',
      <String, Object?>{'focusMinutes': 50},
    );

    expect(result['ok'], isTrue);
    expect((result['result']! as Map)['applied'], 'now');
  });

  test('已经开始过时改：applied=next，本轮时长不变', () async {
    final store = buildStore();
    final bridge = bridgeWith(pomodoro: store);
    await bridge.dispatch('timer.start', <String, Object?>{});

    final result = await bridge.dispatch(
      'timer.configure',
      <String, Object?>{'focusMinutes': 15},
    );

    expect(result['ok'], isTrue, reason: '不报错：改动照样记下，只是本轮不生效');
    expect((result['result']! as Map)['applied'], 'next');
    expect(((result['result']! as Map)['session']! as Map)['plannedSeconds'], 1500);
  });

  test('三个时长可以一起改（联动）', () async {
    final store = buildStore();
    final result = await bridgeWith(pomodoro: store).dispatch(
      'timer.configure',
      <String, Object?>{
        'focusMinutes': 45,
        'shortBreakMinutes': 10,
        'longBreakMinutes': 30,
      },
    );

    expect(result['ok'], isTrue);
    await bridgeWith(pomodoro: store).dispatch('timer.start', <String, Object?>{});
    expect(store.session!.planned, const Duration(minutes: 45));
  });

  test('limit 越界要报错，不是静默截断', () async {
    final store = buildStore();
    final bridge = bridgeWith(pomodoro: store);

    for (final bad in <Object>[0, -1, 999, '10']) {
      final result = await bridge.dispatch('timer.history', <String, Object?>{'limit': bad});
      expect(result['ok'], isFalse, reason: 'limit=$bad 应该被拒');
      expect((result['error']! as Map)['code'], 'bad_params');
    }
  });

  test('since 读不懂要报错（否则会静默返回空列表）', () async {
    final store = buildStore();
    final bridge = bridgeWith(pomodoro: store);

    final bad = await bridge.dispatch(
      'timer.history',
      <String, Object?>{'since': '昨天'},
    );
    expect(bad['ok'], isFalse);
    expect((bad['error']! as Map)['code'], 'bad_params');

    final ok = await bridge.dispatch(
      'timer.history',
      <String, Object?>{'since': '2026-11-01T00:00:00Z'},
    );
    expect(ok['ok'], isTrue);
  });

  test('since 之后的才返回', () async {
    final store = buildStore();
    await store.start();
    fakeNow = fakeNow.add(store.session!.planned);
    await store.debugPump();

    final bridge = bridgeWith(pomodoro: store);
    final before = await bridge.dispatch(
      'timer.history',
      <String, Object?>{'since': '2026-11-03T00:00:00Z'},
    );
    expect(((before['result']! as Map)['sessions']! as List), isEmpty);

    final after = await bridge.dispatch(
      'timer.history',
      <String, Object?>{'since': '2026-11-01T00:00:00Z'},
    );
    expect(((after['result']! as Map)['sessions']! as List), hasLength(1));
  });
}
