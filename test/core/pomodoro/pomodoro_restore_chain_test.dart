import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/state/pomodoro_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';

/// 冷启动恢复这条链路：**过期会话结算 → 事件落库 → 插件能取到**。
///
/// 模拟器上"杀掉进程 → 等过点 → 重开"没落记录，先把链路钉住看是谁的问题。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('恢复时结算的事件必须进事件队列', () async {
    final db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);

    final journal = EventJournal(db);
    HookBus.instance.clear();
    HookBus.instance.register(journal);
    addTearDown(HookBus.instance.clear);

    final settings = SettingsRepository(db);
    final now = DateTime(2026, 11, 2, 10);
    await settings.set(
      SettingsKeys.pomodoroSession,
      jsonEncode(<String, Object?>{
        'phase': 'focus',
        'plannedSeconds': 60,
        'elapsedSeconds': 0,
        'running': true,
        'round': 0,
        'sessionId': 's-killed',
        'runningSince': now.subtract(const Duration(minutes: 5)).toIso8601String(),
      }),
    );

    final store = PomodoroStore(settings: settings, now: () => now);
    addTearDown(store.dispose);
    await store.load();

    expect(store.session!.finished, isTrue);

    final pending = await journal.pending(
      <HookId>{HookId.pomodoroSessionFinished},
      limit: 10,
    );
    expect(pending, hasLength(1), reason: '结算事件必须落进队列，否则插件永远收不到');
    expect(pending.single.payload['sessionId'], 's-killed');
  });
}
