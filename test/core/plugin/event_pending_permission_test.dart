import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_bridge.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';

/// `event.pending` 的权限判据。
///
/// 教训：原来一律要求 `task:read`，结果番茄钟（只声明 notify:local）调 pending
/// 直接被拒 —— 补发通道被堵死，"杀进程那轮的记录"永远补不回来，
/// 而插件那边只是把这个错误吞掉了，表面上看不出任何问题。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late Database db;
  late EventJournal journal;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    journal = EventJournal(db);
    HookBus.instance.clear();
    HookBus.instance.register(journal);
  });

  tearDown(() async {
    HookBus.instance.clear();
    await db.close();
  });

  PluginBridge bridgeWith(Set<HookId> hooks) => PluginBridge(
        pluginId: 'pomodoro',
        version: '1.1.0',
        permissions: <String>{PluginPermissions.notifyLocal},
        tasks: TaskRepository(db),
        settings: SettingsRepository(db),
        contract: PluginContract.current,
        hooks: hooks,
        journal: journal,
      );

  Future<void> seed(HookId hook, Map<String, Object?> payload) =>
      journal.record(HookEvent(hook: hook, payload: payload));

  test('只订阅番茄钟钩子 + 没有 task:read，也能取到补发事件', () async {
    await seed(HookId.pomodoroSessionFinished, <String, Object?>{'sessionId': 's1'});

    final result = await bridgeWith(<HookId>{HookId.pomodoroSessionFinished})
        .dispatch('event.pending', <String, Object?>{'limit': 10});

    expect(result['ok'], isTrue, reason: '不该因为缺 task:read 被拒');
    expect((result['result']! as List), hasLength(1));
  });

  test('订阅了任务类钩子就必须有 task:read（payload 是任务数据）', () async {
    final result = await bridgeWith(<HookId>{HookId.taskCompleted})
        .dispatch('event.pending', <String, Object?>{});

    expect(result['ok'], isFalse);
    expect((result['error']! as Map)['code'], 'permission_denied');
  });
}
