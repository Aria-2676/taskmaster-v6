// 标签管理页的契约测试。
//
// 重点是三件事：新建/改名的**校验要让用户看见为什么不行**、
// 删除标签**不能顺手删掉任务**、改名后**正在生效的筛选要跟着走**。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/pages/tag_manager_page.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;
  late TaskStore store;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    repo = TaskRepository(db);
    store = TaskStore(repo, SettingsRepository(db));
    await store.load();
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: TagManagerPage(store: store)));
    await settle(tester);
  }

  testWidgets('空状态：显示提示，不显示任何行', (tester) async {
    await pumpPage(tester);
    expect(find.text('还没有标签'), findsOneWidget);
  });

  testWidgets('新建标签：出现在列表里，并写进库', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '阅读');
    await tester.tap(find.text('新建'));
    await settle(tester);

    expect(find.text('阅读'), findsOneWidget);
    expect((await repo.allTags()).map((t) => t.name), contains('阅读'));
    expect(find.text('未使用'), findsOneWidget);
  });

  testWidgets('重名：错误显示在输入框里，弹窗不关', (tester) async {
    await repo.insertTag(const Tag(id: 0, name: '工作'));
    await store.load();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '工作');
    await tester.tap(find.text('新建'));
    await settle(tester);

    expect(find.text('已经有叫「工作」的标签了'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget, reason: '不能关掉弹窗让用户重填');
    expect((await repo.allTags()).length, 1, reason: '一条都不该多出来');
  });

  testWidgets('空名字：直接拒绝，不写库', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('新建'));
    await settle(tester);

    expect(find.text('标签名不能为空'), findsOneWidget);
    expect(await repo.allTags(), isEmpty);
  });

  testWidgets('改名：列表与任务上的标签名一起变', (tester) async {
    await repo.insertTag(const Tag(id: 0, name: '工作'));
    final tag = (await repo.allTags()).single;
    await repo.insert(title: '写周报', day: DateTime.now(), tagIds: <int>[tag.id]);
    await store.load();
    await pumpPage(tester);

    expect(find.text('1 个任务'), findsOneWidget);

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '工作事项');
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(find.text('工作事项'), findsOneWidget);
    expect(store.tasks.single.tags.single.name, '工作事项',
        reason: '任务上的标签名要跟着变，否则筛选对不上');
  });

  testWidgets('删除：明确说出有几个任务在用，任务本身留着', (tester) async {
    await repo.insertTag(const Tag(id: 0, name: '工作'));
    final tag = (await repo.allTags()).single;
    await repo.insert(title: '写周报', day: DateTime.now(), tagIds: <int>[tag.id]);
    await store.load();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('删除标签'));
    await tester.pumpAndSettle();

    expect(find.textContaining('有 1 个任务正在使用「工作」'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester);

    expect(await repo.allTags(), isEmpty);
    final tasks = await repo.tasksOn(DateTime.now());
    expect(tasks.single.title, '写周报', reason: '删标签不能删任务');
    expect(tasks.single.tags, isEmpty);
    expect(find.text('还没有标签'), findsOneWidget);
  });

  testWidgets('删掉正在筛选的标签：筛选自动回到「全部」', (tester) async {
    await repo.insertTag(const Tag(id: 0, name: '工作'));
    final tag = (await repo.allTags()).single;
    await store.load();
    store.setTagFilter('工作');
    await pumpPage(tester);

    await tester.tap(find.byTooltip('删除标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle(tester);

    expect(store.tagFilter, isNull, reason: '标签没了还按它筛选，列表会一直是空的');
    expect(tag.id, greaterThan(0));
  });
}
