// v6 数据层的 schema 契约测试。
//
// 重点不是"能建表"，而是三条**不可退让的事实**：
//   1. tasks 表里**没有**货币字段（reward_points / is_deducted 已移出主包）
//   2. tasks 表里**有** estimated_minutes（货币插件靠它计价）
//   3. 插件表只能以 plg_<id>_ 前缀存在，卸载时前缀守卫必须挡住误删主包表

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';

Future<Set<String>> _columnsOf(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openDb([PluginSchemaRegistry? schema]) =>
      V6Database.open(path: inMemoryDatabasePath, pluginSchema: schema ?? PluginSchemaRegistry());

  group('主包 schema', () {
    test('建库后 5 张业务表 + 插件迁移表都在，番茄钟表已移出', () async {
      final db = await openDb();
      addTearDown(db.close);

      final tables = await V6Database.listTables(db);
      for (final name in V6Table.businessTables) {
        expect(tables, contains(name), reason: '缺少主包表 $name');
      }
      expect(tables, contains(V6Table.pluginMigrations));

      // 番茄钟会话记录归插件，主包不该有这两张表
      expect(tables, isNot(contains(V6Table.legacyPomodoroRecords)));
      expect(tables, isNot(contains(V6Table.legacyPomodoroSettings)));
    });

    test('tasks 不含货币字段（已移出主包）', () async {
      final db = await openDb();
      addTearDown(db.close);

      final cols = await _columnsOf(db, V6Table.tasks);
      expect(cols, isNot(contains(TaskCol.legacyRewardPoints)));
      expect(cols, isNot(contains(TaskCol.legacyIsDeducted)));
    });

    test('tasks 含 estimated_minutes', () async {
      final db = await openDb();
      addTearDown(db.close);

      final cols = await _columnsOf(db, V6Table.tasks);
      expect(cols, contains(TaskCol.estimatedMinutes));
    });

    test('列名常量可直接用于读写（不是摆设）', () async {
      final db = await openDb();
      addTearDown(db.close);

      final id = await db.insert(V6Table.tasks, <String, Object?>{
        TaskCol.title: '写完这节',
        TaskCol.cplTime: '2026-10-22',
        TaskCol.createdAt: '2026-10-22T02:00:00',
        TaskCol.estimatedMinutes: 30,
      });

      final rows = await db.query(
        V6Table.tasks,
        where: '${TaskCol.id} = ?',
        whereArgs: <Object?>[id],
      );
      expect(rows, hasLength(1));
      expect(rows.first[TaskCol.title], '写完这节');
      expect(rows.first[TaskCol.estimatedMinutes], 30);
      expect(rows.first[TaskCol.priority], 'white', reason: '默认优先级应为 white');
    });

    test('外键级联：删任务时 task_tags 跟着删', () async {
      final db = await openDb();
      addTearDown(db.close);

      final taskId = await db.insert(V6Table.tasks, <String, Object?>{
        TaskCol.title: 't',
        TaskCol.cplTime: '2026-10-22',
        TaskCol.createdAt: '2026-10-22T02:00:00',
      });
      final tagId = await db.insert(V6Table.tags, <String, Object?>{
        TagCol.name: '工作',
        TagCol.createdAt: '2026-10-22T02:00:00',
      });
      await db.insert(V6Table.taskTags, <String, Object?>{
        TaskTagCol.taskId: taskId,
        TaskTagCol.tagId: tagId,
      });

      await db.delete(V6Table.tasks, where: '${TaskCol.id} = ?', whereArgs: <Object?>[taskId]);

      final left = await db.query(V6Table.taskTags);
      expect(left, isEmpty, reason: '外键级联未生效，说明 PRAGMA foreign_keys 没开');
    });
  });

  group('插件表', () {
    test('注册后建表并登记版本', () async {
      final schema = PluginSchemaRegistry()
        ..register(const PluginTableSpec(
          pluginId: 'energy',
          suffix: 'records',
          columnsSql: 'id INTEGER PRIMARY KEY AUTOINCREMENT, delta INTEGER NOT NULL',
        ));
      final db = await openDb(schema);
      addTearDown(db.close);

      final tables = await V6Database.listTables(db);
      expect(tables, contains('plg_energy_records'));

      final rows = await db.query(V6Table.pluginMigrations);
      expect(rows, hasLength(1));
      expect(rows.first[PluginMigrationCol.tableName], 'plg_energy_records');
      expect(rows.first[PluginMigrationCol.version], 1);
    });

    test('卸载插件：删表 + 删迁移记录', () async {
      final schema = PluginSchemaRegistry()
        ..register(const PluginTableSpec(
          pluginId: 'energy',
          suffix: 'records',
          columnsSql: 'id INTEGER PRIMARY KEY AUTOINCREMENT',
        ));
      final db = await openDb(schema);
      addTearDown(db.close);

      await schema.dropPlugin(db, 'energy');

      final tables = await V6Database.listTables(db);
      expect(tables, isNot(contains('plg_energy_records')));
      expect(await db.query(V6Table.pluginMigrations), isEmpty);
    });

    test('前缀守卫：迁移记录被篡改成主包表也不会被删', () async {
      final db = await openDb();
      addTearDown(db.close);

      // 模拟一条被污染的记录，指向主包表
      await db.insert(V6Table.pluginMigrations, <String, Object?>{
        PluginMigrationCol.pluginId: 'evil',
        PluginMigrationCol.tableName: V6Table.tasks,
        PluginMigrationCol.version: 1,
        PluginMigrationCol.createdAt: '2026-10-22T02:00:00',
      });

      await PluginSchemaRegistry().dropPlugin(db, 'evil');

      final tables = await V6Database.listTables(db);
      expect(tables, contains(V6Table.tasks), reason: '主包表被误删了');
    });

    test('非法插件 id 直接抛错（安装期就该失败）', () {
      expect(
        () => PluginSchemaRegistry().register(const PluginTableSpec(
          pluginId: 'Energy_Plugin',
          suffix: 'records',
          columnsSql: 'id INTEGER',
        )),
        throwsArgumentError,
      );
    });
  });
}
