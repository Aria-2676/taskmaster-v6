// 备份 / 恢复的领域层。
//
// 全部跑真库（in-memory）：这层最容易出的错是"列对不上""表不存在"，
// 用假数据替身反而测不出来。

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/backup/backup_service.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late BackupService service;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    service = BackupService(db);

    await db.insert(V6Table.tasks, <String, Object?>{
      TaskCol.id: 1,
      TaskCol.title: '买牛奶',
      TaskCol.createdAt: '2026-10-28T01:00:00Z',
      TaskCol.cplTime: '2026-10-28',
    });
    await db.insert(V6Table.tasks, <String, Object?>{
      TaskCol.id: 2,
      TaskCol.title: '写周报',
      TaskCol.createdAt: '2026-10-28T02:00:00Z',
      TaskCol.cplTime: '2026-10-28',
    });
    await db.insert(V6Table.tags, <String, Object?>{
      TagCol.id: 1,
      TagCol.name: '家务',
      TagCol.createdAt: '2026-10-28T00:00:00Z',
    });
    await db.insert(V6Table.taskTags, <String, Object?>{
      TaskTagCol.taskId: 1,
      TaskTagCol.tagId: 1,
    });
    await db.insert(V6Table.settings, <String, Object?>{
      SettingsCol.key: 'ui.recycle_retention_days',
      SettingsCol.value: '7',
    });
    // 插件私有表 + KV：判据是"表在不在"，所以要真的建出来
    await db.execute('CREATE TABLE plg_demo_a_entries (id INTEGER PRIMARY KEY, note TEXT)');
    // 真实流程里插件建表时会写这一行；清单靠它认 id（id 本身可能带下划线）
    await db.insert(V6Table.pluginMigrations, <String, Object?>{
      'plugin_id': 'demo_a',
      'table_name': 'plg_demo_a_entries',
      'version': 1,
      'created_at': '2026-10-28T00:00:00Z',
    });
    await db.insert('plg_demo_a_entries', <String, Object?>{'note': '第一条'});
    await db.insert(V6Table.settings, <String, Object?>{
      SettingsCol.key: 'plg.demo_a.streak',
      SettingsCol.value: '5',
    });
  });

  tearDown(() => db.close());

  Future<BackupData> snapshot() => service.collect(
        appVersion: '6.0.0+6000',
        recycleBin: false,
        pluginIds: const <String>{'demo_a'},
      );

  group('打包与解包', () {
    test('round-trip：内容与清单都对得上', () async {
      final data = await snapshot();
      final bytes = service.pack(data);
      final restored = service.unpack(bytes);

      expect(restored.tasks, hasLength(2));
      expect(restored.tags, hasLength(1));
      expect(restored.taskTags, hasLength(1));
      expect(restored.settings['ui.recycle_retention_days'], '7');
      expect(restored.plugins['demo_a']?.tables['plg_demo_a_entries'], hasLength(1));
      expect(restored.plugins['demo_a']?.kv['streak'], '5');

      expect(restored.manifest.counts['tasks'], 2);
      expect(restored.manifest.summary, contains('任务 2'));
      expect(restored.manifest.appVersion, '6.0.0+6000');
    });

    test('插件 KV 不会混进主包设置里', () async {
      final data = await snapshot();
      expect(data.settings.containsKey('plg.demo_a.streak'), isFalse);
    });

    test('不是 zip 的文件：给一句人话，不抛原始异常', () {
      expect(
        () => service.unpack(utf8.encode('这不是压缩包')),
        throwsA(isA<BackupException>()),
      );
    });

    test('zip 里不是本产品的清单：拒绝', () {
      final archive = Archive();
      final manifest = utf8.encode(jsonEncode(<String, Object?>{'format': 'other'}));
      archive.addFile(ArchiveFile(BackupFormat.manifestEntry, manifest.length, manifest));
      final bytes = ZipEncoder().encode(archive);

      expect(() => service.unpack(bytes), throwsA(isA<BackupException>()));
    });
  });

  group('恢复', () {
    test('覆盖语义：恢复后与备份时一致', () async {
      final data = await snapshot();

      // 把库改乱
      await db.delete(V6Table.tasks);
      await db.insert(V6Table.tasks, <String, Object?>{
        TaskCol.id: 9,
        TaskCol.title: '多出来的',
        TaskCol.createdAt: '2026-10-29T00:00:00Z',
        TaskCol.cplTime: '2026-10-29',
      });
      await db.delete('plg_demo_a_entries');

      final report = await service.restore(data, pluginIds: const <String>{'demo_a'});

      final tasks = await db.query(V6Table.tasks);
      expect(tasks.map((r) => r['title']), containsAll(<String>['买牛奶', '写周报']));
      expect(tasks, hasLength(2), reason: '覆盖后不该还留着"多出来的"');
      expect(report.written['任务'], 2);
      expect(await db.query('plg_demo_a_entries'), hasLength(1));
    });

    test('设置只覆盖备份里有的键，不清空整表', () async {
      final data = await snapshot();
      // 机器状态：不能被恢复清掉
      await db.insert(V6Table.settings, <String, Object?>{
        SettingsCol.key: 'app_update_ignored_version',
        SettingsCol.value: '6.0.1',
      });
      await db.insert(
        V6Table.settings,
        <String, Object?>{
          SettingsCol.key: 'ui.recycle_retention_days',
          SettingsCol.value: '30',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await service.restore(data);

      final ignored = await db.query(V6Table.settings,
          where: 'key = ?', whereArgs: <Object?>['app_update_ignored_version']);
      expect(ignored.single['value'], '6.0.1', reason: '机器状态不该被备份覆盖掉');
      final retention = await db.query(V6Table.settings,
          where: 'key = ?', whereArgs: <Object?>['ui.recycle_retention_days']);
      expect(retention.single['value'], '7', reason: '备份里有的键要恢复成备份值');
    });

    test('备份里有、当前没装也没表：整段跳过并记进报告', () async {
      final data = await snapshot();
      await db.execute('DROP TABLE plg_demo_a_entries');
      await db.delete(V6Table.settings, where: 'key LIKE ?', whereArgs: <Object?>['plg.demo_a.%']);

      final report = await service.restore(data, pluginIds: const <String>{'demo_a'});

      expect(report.skippedPlugins, contains('demo_a'));
      expect(report.hasLoss, isTrue);
    });

    test('缺列：丢弃但写进报告，其它列照常恢复', () async {
      final data = await snapshot();
      // 模拟"备份是旧版本打的"：数据里多一列
      final patched = BackupData(
        manifest: data.manifest,
        tasks: <Map<String, Object?>>[
          <String, Object?>{...data.tasks.first, 'column_removed_in_v6': '孤儿值'},
          ...data.tasks.skip(1),
        ],
        tags: data.tags,
        taskTags: data.taskTags,
        recycled: data.recycled,
        settings: data.settings,
        plugins: data.plugins,
      );

      final report = await service.restore(patched);

      expect(report.droppedColumns, contains('tasks.column_removed_in_v6'));
      expect(await db.query(V6Table.tasks), hasLength(2), reason: '其它列要照常写进去');
    });
  });

  group('现存插件数据清单', () {
    test('没装但表还在：标记为未安装，且行数不为零', () async {
      final infos = await service.listPluginData();

      expect(infos, hasLength(1));
      expect(infos.single.pluginId, 'demo_a');
      expect(infos.single.installed, isFalse, reason: 'installed_plugins 里没有它');
      expect(infos.single.rowCount, greaterThan(0), reason: '表和 KV 加起来至少 2 条');
      expect(infos.single.tableCount, 1);
    });

    test('装了之后：installed 为 true 且带版本号', () async {
      await db.insert(V6Table.installedPlugins, <String, Object?>{
        'plugin_id': 'demo_a',
        'version': '1.2.0',
        'contract': 1,
        'install_dir': 'demo_a/1.2.0',
        'installed_at': '2026-10-28T00:00:00Z',
        'enabled': 1,
      });

      final infos = await service.listPluginData();
      expect(infos.single.installed, isTrue);
      expect(infos.single.version, '1.2.0');
    });
  });
}
