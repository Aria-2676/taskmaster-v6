// 任务编辑页的契约测试。
//
// 盯三件事：
//   1. 打开时**显示的是任务当前的值**（不是默认值）
//   2. 保存后**库里真的变了**（只看界面关没关不算数）
//   3. 有改动时按返回**不能静默丢弃**

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/pages/task_editor_page.dart';
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
  late Task task;
  TaskEditOutcome? outcome;

  final today = DateTime.now();
  final day = DateTime(today.year, today.month, today.day);

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    repo = TaskRepository(db);
    store = TaskStore(repo, SettingsRepository(db));

    await repo.insertTag(const Tag(id: 0, name: '工作'));
    await repo.insertTag(const Tag(id: 0, name: '学习'));
    final tags = await repo.allTags();
    await repo.insert(
      title: '写周报',
      day: day,
      description: '本周进展',
      priority: 'blue',
      estimatedMinutes: 30,
      tagIds: <int>[tags.firstWhere((t) => t.name == '工作').id],
    );
    await store.load(day);
    task = store.tasks.single;
    outcome = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> openPage(
    WidgetTester tester, {
    Task? target,
    DateTime? initialDay,
    Future<bool> Function()? onDelete,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  outcome = await Navigator.of(context).push<TaskEditOutcome>(
                    MaterialPageRoute<TaskEditOutcome>(
                      builder: (_) => TaskEditorPage(
                        store: store,
                        task: target,
                        initialDay: initialDay,
                        onDelete: onDelete,
                      ),
                    ),
                  );
                },
                child: const Text('打开编辑'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑'));
    await settle(tester);
  }

  Future<void> openEditor(
    WidgetTester tester, {
    Future<bool> Function()? onDelete,
  }) =>
      openPage(
        tester,
        target: task,
        onDelete: onDelete ?? () async => false,
      );

  Future<void> openCreate(WidgetTester tester, {DateTime? initialDay}) =>
      openPage(tester, initialDay: initialDay ?? day);

  testWidgets('打开时显示任务当前的值', (tester) async {
    await openEditor(tester);

    expect(find.text('编辑任务'), findsOneWidget);
    expect(find.widgetWithText(TextField, '写周报'), findsOneWidget);
    expect(find.widgetWithText(TextField, '本周进展'), findsOneWidget);
    expect(find.textContaining('今天'), findsOneWidget, reason: '日期行要带"今天"');
    expect(find.text('30 分钟'), findsOneWidget);
    // 标签 chip 的选中态：工作被选中、学习没有
    expect(find.widgetWithText(FilterChip, '工作'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '学习'), findsOneWidget);
  });

  testWidgets('改标题并保存：库里的标题变了', (tester) async {
    await openEditor(tester);

    await tester.enterText(find.widgetWithText(TextField, '写周报'), '写月报');
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(outcome, TaskEditOutcome.saved);
    final saved = (await repo.tasksOn(day)).single;
    expect(saved.title, '写月报');
    expect(saved.description, '本周进展', reason: '没改的字段不能被清空');
  });

  testWidgets('标题清空：拦下来，不关页面也不写库', (tester) async {
    await openEditor(tester);

    await tester.enterText(find.widgetWithText(TextField, '写周报'), '   ');
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(find.text('标题不能为空'), findsOneWidget);
    expect(outcome, isNull);
    expect((await repo.tasksOn(day)).single.title, '写周报');
  });

  testWidgets('改标签：加一个、减一个都要落到 task_tags', (tester) async {
    await openEditor(tester);

    await tester.tap(find.widgetWithText(FilterChip, '学习')); // 加上
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '工作')); // 去掉
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settle(tester);

    final saved = (await repo.tasksOn(day)).single;
    expect(saved.tags.map((t) => t.name), <String>['学习']);
  });

  testWidgets('改优先级与预计时长：保存后生效', (tester) async {
    await openEditor(tester);

    await tester.tap(find.text('红'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 分钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settle(tester);

    final saved = (await repo.tasksOn(day)).single;
    expect(saved.priority, 'red');
    expect(saved.estimatedMinutes, 60);
  });

  testWidgets('有改动时按返回：先问「放弃修改？」', (tester) async {
    await openEditor(tester);

    await tester.enterText(find.widgetWithText(TextField, '写周报'), '写月报');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await settle(tester);

    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await settle(tester);

    expect(find.text('编辑任务'), findsOneWidget, reason: '选择继续编辑就不该退出');
    expect(outcome, isNull);

    // 再来一次，这次放弃
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.text('放弃'));
    await settle(tester);

    expect(outcome, isNull, reason: '放弃修改不是"保存"');
    expect((await repo.tasksOn(day)).single.title, '写周报');
  });

  testWidgets('新建模式：标题是「新建任务」，且没有删除入口', (tester) async {
    await openCreate(tester);

    expect(find.text('新建任务'), findsOneWidget);
    expect(find.text('编辑任务'), findsNothing);
    expect(find.text('删除任务'), findsNothing, reason: '还没建出来的东西删不了');
    expect(find.text('添加'), findsOneWidget);
  });

  testWidgets('新建模式：填标题保存后库里多一条', (tester) async {
    await openCreate(tester);

    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.text('添加'));
    await settle(tester);

    expect(outcome, TaskEditOutcome.saved);
    final titles = (await repo.tasksOn(day)).map((t) => t.title).toList();
    expect(titles, contains('买牛奶'));
    expect(titles.length, 2, reason: '原来那条要还在');
  });

  testWidgets('新建模式：一次就能把优先级/时长/标签都填好', (tester) async {
    await openCreate(tester);

    await tester.enterText(find.byType(TextField).first, '整理房间');
    await tester.pumpAndSettle();
    await tester.tap(find.text('红'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 分钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '学习'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await settle(tester);

    final created = (await repo.tasksOn(day)).firstWhere((t) => t.title == '整理房间');
    expect(created.priority, 'red');
    expect(created.estimatedMinutes, 60);
    expect(created.tags.map((t) => t.name), <String>['学习']);
  });

  testWidgets('新建模式：标题为空时拦住，不写库', (tester) async {
    await openCreate(tester);

    await tester.tap(find.text('添加'));
    await settle(tester);

    expect(find.text('标题不能为空'), findsOneWidget);
    expect(outcome, isNull);
    expect((await repo.tasksOn(day)).length, 1);
  });

  testWidgets('点删除：交给外层执行，成功后关闭页面并返回 deleted', (tester) async {
    var called = 0;
    await openEditor(tester, onDelete: () async {
      called++;
      return true;
    });

    await tester.tap(find.text('删除任务'));
    await settle(tester);

    expect(called, 1);
    expect(outcome, TaskEditOutcome.deleted);
  });
}
