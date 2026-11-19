// 全局搜索的查询层。
//
// 两条容易错的地方都锁在这里：
//   1. LIKE 的 `%` / `_` 必须转义 —— 用户真会搜「100%」
//   2. 已完成的要搜出来，但排在未完成之后（用户 2026-11-19 定的）

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;
  final today = DateTime(2026, 11, 19);

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    repo = TaskRepository(db);
  });

  test('标题和描述都搜', () async {
    await repo.insert(title: '买牛奶', day: today);
    await repo.insert(title: '写周报', day: today, description: '记得提牛奶的事');

    final hits = await repo.search('牛奶');
    expect(hits.map((t) => t.title), containsAll(<String>['买牛奶', '写周报']));
  });

  test('已完成的也搜出来，但排在未完成后面', () async {
    final doneId = await repo.insert(title: '读完了', day: today);
    await repo.setDone(doneId, true);
    await repo.insert(title: '读一点', day: today);

    final hits = await repo.search('读');
    expect(hits, hasLength(2));
    expect(hits.first.title, '读一点', reason: '未完成的排前面');
    expect(hits.last.isDone, isTrue);
  });

  test('百分号按字面匹配，不当通配符', () async {
    await repo.insert(title: '完成度 100%', day: today);
    await repo.insert(title: '完全无关的任务', day: today);

    final hits = await repo.search('100%');
    expect(hits.map((t) => t.title), <String>['完成度 100%'],
        reason: '% 没转义的话会匹配到所有任务');
  });

  test('下划线也按字面匹配', () async {
    await repo.insert(title: 'a_b', day: today);
    await repo.insert(title: 'axb', day: today);

    final hits = await repo.search('a_b');
    expect(hits.map((t) => t.title), <String>['a_b']);
  });

  test('空关键词返回空，不打全表', () async {
    await repo.insert(title: '随便', day: today);
    expect(await repo.search('   '), isEmpty);
  });
}
