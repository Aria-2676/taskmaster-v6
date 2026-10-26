// v6 的第一条迁移（1 → 2）：给 recycled_tasks 补 tag_ids。
//
// 这条测试的意义不在"列加上了"，而在**老设备上的库能被打开**。
// 迁移写错的表现是：新装用户一切正常，升级用户直接打不开 app——
// 而我们的测试全跑在新库上，永远不会发现。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_schema.dart';

/// v1 时代的 `recycled_tasks`：**没有 tag_ids**。
/// 刻意手写而不复用现在的 DDL —— 复用会让"忘了加列"变成测试也测不出来。
const String _v1RecycledDdl = '''
CREATE TABLE recycled_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER,
  loop_id TEXT,
  title TEXT NOT NULL,
  description TEXT,
  is_word INTEGER NOT NULL DEFAULT 0,
  is_ok INTEGER NOT NULL DEFAULT 0,
  cpl_time TEXT NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  completed_at TEXT,
  estimated_minutes INTEGER,
  created_at TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'white',
  deleted_at TEXT NOT NULL
)
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v1 老库升到 v2：补上 tag_ids，旧数据不丢', () async {
    final dir = await Directory.systemTemp.createTemp('v6_migration');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'v6_tasks.db');

    // 造一个真实的 v1 库（只建这次迁移涉及的这张表）
    final old = await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute(_v1RecycledDdl);
    });
    await old.insert('recycled_tasks', <String, Object?>{
      'title': '升级前就在回收站里的任务',
      'cpl_time': '2026-10-22',
      'created_at': '2026-10-22T00:00:00.000Z',
      'deleted_at': '2026-10-22T00:00:00.000Z',
    });
    await old.close();

    // 用当前代码打开 —— 这一步会走 onUpgrade
    final db = await V6Database.open(path: path);
    addTearDown(db.close);

    final columns = await db.rawQuery('PRAGMA table_info(${V6Table.recycledTasks})');
    expect(
      columns.map((c) => c['name']),
      contains(RecycledTaskCol.tagIds),
      reason: '迁移必须补上 tag_ids 列',
    );

    final rows = await db.query(V6Table.recycledTasks);
    expect(rows, hasLength(1), reason: '迁移不能把这行弄丢');
    expect(rows.single['title'], '升级前就在回收站里的任务');
    expect(rows.single[RecycledTaskCol.tagIds], isNull, reason: '老数据没有标签快照，为空是正常的');
  });

  test('新库建出来就是 v2：tag_ids 列存在', () async {
    final db = await V6Database.open(path: inMemoryDatabasePath);
    addTearDown(db.close);

    final columns = await db.rawQuery('PRAGMA table_info(${V6Table.recycledTasks})');
    expect(columns.map((c) => c['name']), contains(RecycledTaskCol.tagIds));
    expect(V6Database.version, 2);
  });
}
