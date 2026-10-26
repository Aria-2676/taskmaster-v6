// v6 任务仓储的契约测试。
//
// 覆盖的是"数据落在哪儿、按什么顺序出来"这三类最容易被悄悄改坏的事：
//   1. 按日期取任务（日期是 `yyyy-MM-dd` 字符串，走索引）
//   2. 排序：未完成在前 → 优先级 → 创建时间
//   3. 删除是"拷到回收站再删原行"，不是直接删

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/demo_seed.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(Database, TaskRepository)> open() async {
    final db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    return (db, TaskRepository(db));
  }

  test('插入后按日期取回，标签一起带出', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    await repo.insertTag(const Tag(id: 0, name: '工作'));
    final tags = await repo.allTags();
    final day = DateTime(2026, 10, 22);

    await repo.insert(
      title: '写测试',
      day: day,
      estimatedMinutes: 30,
      tagIds: <int>[tags.first.id],
    );

    final list = await repo.tasksOn(day);
    expect(list, hasLength(1));
    expect(list.single.title, '写测试');
    expect(list.single.estimatedMinutes, 30);
    expect(list.single.tags.map((t) => t.name), <String>['工作']);

    // 换一天就取不到
    expect(await repo.tasksOn(day.add(const Duration(days: 1))), isEmpty);
  });

  test('完成态会写/清 completed_at', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: 'A', day: day);

    await repo.setDone(id, true);
    var task = (await repo.tasksOn(day)).single;
    expect(task.isDone, isTrue);
    expect(task.completedAt, isNotNull);

    await repo.setDone(id, false);
    task = (await repo.tasksOn(day)).single;
    expect(task.isDone, isFalse);
    expect(task.completedAt, isNull);
  });

  test('排序：未完成在前，其次优先级，再按创建时间', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final whiteId = await repo.insert(title: '白', day: day, priority: 'white');
    await repo.insert(title: '蓝', day: day, priority: 'blue');
    await repo.insert(title: '红-后', day: day, priority: 'red');
    // 一条已完成的红，应该排到最后
    final doneRed = await repo.insert(title: '红-已完成', day: day, priority: 'red');
    await repo.setDone(doneRed, true);
    expect(whiteId, greaterThan(0));

    final titles = (await repo.tasksOn(day)).map((t) => t.title).toList();
    expect(titles, <String>['红-后', '蓝', '白', '红-已完成']);
  });

  test('删除是移入回收站：任务表没了，回收站留一份', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: '要被删的', day: day, estimatedMinutes: 45);

    await repo.moveToRecycle(id);

    expect(await repo.tasksOn(day), isEmpty);

    final rows = await db.query(V6Table.recycledTasks);
    expect(rows, hasLength(1));
    expect(rows.single[RecycledTaskCol.title], '要被删的');
    expect(rows.single[RecycledTaskCol.taskId], id);
    expect(rows.single[RecycledTaskCol.estimatedMinutes], 45);
    expect(rows.single[RecycledTaskCol.deletedAt], isNotNull);
  });

  test('delete(toRecycle: false) 是物理删除，回收站不留东西', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: '直接删', day: day);

    await repo.delete(id, toRecycle: false);

    expect(await repo.tasksOn(day), isEmpty);
    expect(await repo.recycledCount(), 0, reason: '默认模式不该悄悄留垃圾');
  });

  test('delete(toRecycle: true) 走回收站', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: '进回收站', day: day);

    await repo.delete(id, toRecycle: true);

    expect(await repo.tasksOn(day), isEmpty);
    expect(await repo.recycledCount(), 1);
  });

  test('恢复：拷回任务表，回收站那行删掉', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: '误删的', day: day, estimatedMinutes: 30);
    await repo.moveToRecycle(id);

    final recycled = (await repo.recycledTasks()).single;
    await repo.restoreFromRecycle(recycled.id);

    final restored = await repo.tasksOn(day);
    expect(restored, hasLength(1));
    expect(restored.single.title, '误删的');
    expect(restored.single.estimatedMinutes, 30, reason: '字段要原样带回来');
    expect(restored.single.id, isNot(id), reason: '拿新 id，旧 id 已经让给自增序列了');
    expect(await repo.recycledCount(), 0);
  });

  test('恢复带标签：task_tags 一起回来', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    await repo.insertTag(const Tag(id: 0, name: '工作'));
    await repo.insertTag(const Tag(id: 0, name: '学习'));
    final tags = await repo.allTags();

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(
      title: '带两个标签',
      day: day,
      tagIds: tags.map((t) => t.id).toList(),
    );

    await repo.moveToRecycle(id);
    final recycled = (await repo.recycledTasks()).single;
    expect(recycled.tagIds.toSet(), tags.map((t) => t.id).toSet(),
        reason: '删除时要留下标签快照');

    await repo.restoreFromRecycle(recycled.id);

    final restored = (await repo.tasksOn(day)).single;
    expect(restored.tags.map((t) => t.name).toSet(), <String>{'工作', '学习'},
        reason: '恢复出来的任务必须带着原来的标签');
  });

  test('标签后来被删了：恢复仍然成功，只是少了那个标签', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    await repo.insertTag(const Tag(id: 0, name: '临时'));
    final tag = (await repo.allTags()).single;

    final day = DateTime(2026, 10, 22);
    final id = await repo.insert(title: '标签会被删', day: day, tagIds: <int>[tag.id]);
    await repo.moveToRecycle(id);

    // 标签本身被删掉（外键 CASCADE 会连带清掉 task_tags）
    await db.delete(V6Table.tags, where: '${TagCol.id} = ?', whereArgs: <Object?>[tag.id]);

    final recycled = (await repo.recycledTasks()).single;
    await repo.restoreFromRecycle(recycled.id);

    final restored = (await repo.tasksOn(day)).single;
    expect(restored.title, '标签会被删', reason: '外键不该让整条恢复失败');
    expect(restored.tags, isEmpty);
  });

  test('到期清理：只删超过保留期的', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final day = DateTime(2026, 10, 22);
    final oldId = await repo.insert(title: '十天后', day: day);
    final newId = await repo.insert(title: '刚刚', day: day);
    await repo.moveToRecycle(oldId);
    await repo.moveToRecycle(newId);

    // 手动把一条改成 10 天前删的
    await db.update(
      V6Table.recycledTasks,
      <String, Object?>{
        RecycledTaskCol.deletedAt:
            TaskDate.timeKey(DateTime.now().subtract(const Duration(days: 10))),
      },
      where: '${RecycledTaskCol.title} = ?',
      whereArgs: <Object?>['十天后'],
    );

    final removed = await repo.purgeRecycleOlderThan(const Duration(days: 7));

    expect(removed, 1);
    final left = await repo.recycledTasks();
    expect(left.single.title, '刚刚');
  });

  test('dailyCounts 按日期分组', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    final d1 = DateTime(2026, 10, 22);
    final d2 = DateTime(2026, 10, 23);
    await repo.insert(title: 'a', day: d1);
    await repo.insert(title: 'b', day: d1);
    await repo.insert(title: 'c', day: d2);

    final counts = await repo.dailyCounts(d1, d2);
    expect(counts[TaskDate.parseDay('2026-10-22')], 2);
    expect(counts[TaskDate.parseDay('2026-10-23')], 1);
  });

  test('演示数据只在空库时写入', () async {
    final (db, repo) = await open();
    addTearDown(db.close);

    await DemoSeed.runIfEmpty(repo);
    final first = await repo.tasksOn(DateTime.now());
    expect(first, isNotEmpty);

    // 再跑一次不该翻倍
    await DemoSeed.runIfEmpty(repo);
    expect((await repo.tasksOn(DateTime.now())).length, first.length);
  });
}
