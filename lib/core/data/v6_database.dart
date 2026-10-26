// v6 数据层 —— 打开 / 建库 / 主包表初始化。
//
// 与 v5 的差别：
//   - 库名换成 `v6_tasks.db`，避免误读 v5 的 `v5_tasks.db`
//   - **没有迁移链**：version 固定 1，v5 的 1→2→3 历史不再延续
//   - 打开时顺带物化插件表（幂等），这样"装完插件重启"和"首次建库"走同一条路

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'v6_plugin_tables.dart';
import 'v6_schema.dart';

class V6Database {
  V6Database._();

  static const String fileName = 'v6_tasks.db';

  /// v6 的 schema 版本。
  ///
  /// - 1：初始结构
  /// - 2：`recycled_tasks.tag_ids`（回收站保留标签快照，恢复时用来重建 `task_tags`）
  static const int version = 2;

  /// 打开数据库（不存在则创建）。
  ///
  /// [path] 为空时放在 sqflite 的默认库目录；测试可传 [inMemoryDatabasePath]。
  /// [pluginSchema] 默认用全局注册表，测试可注入独享实例。
  static Future<Database> open({
    String? path,
    String? directory,
    PluginSchemaRegistry? pluginSchema,
  }) async {
    final dbPath = path ??
        (directory == null
            ? p.join(await getDatabasesPath(), fileName)
            : p.join(directory, fileName));

    final registry = pluginSchema ?? PluginSchemaRegistry.instance;

    return openDatabase(
      dbPath,
      version: version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        for (final sql in v6CreateTables) {
          await db.execute(sql);
        }
        for (final sql in v6CreateIndexes) {
          await db.execute(sql);
        }
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 迁移链从 1 开始。**每一步都要能单独跑通**：老设备可能停在任意版本，
        // 所以按"低于目标就补一步"写，而不是 if (old == 1) 的二分。
        if (newVersion > version) {
          throw StateError('v6 迁移链只到 $version，请求升到 $newVersion');
        }
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE ${V6Table.recycledTasks} '
            'ADD COLUMN ${RecycledTaskCol.tagIds} TEXT',
          );
        }
      },
    ).then((db) async {
      await registry.materialize(db);
      // 幂等补建：这两张表都是 schema 定稿之后才加的，老库上不会有
      await db.execute(v6InstalledPluginsDdl);
      await db.execute(v6PluginEventsDdl);
      return db;
    });
  }

  /// 库里的全部表名（含插件表）。诊断与测试用。
  static Future<List<String>> listTables(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    return rows.map((r) => r['name'] as String).toList();
  }
}
