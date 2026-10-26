// 逾期任务：**看不见就等于丢了**。
//
// 这条链路有三段，任何一段断掉都会让用户"以为自己做完了"或者"以为任务没了"：
//   1. 查询：只取更早的、未完成的
//   2. 展示：首页要能看见，并且和当天任务分得开
//   3. 出路：能勾掉，也能挪到当前这天

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/pages/v6_home_page.dart';
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
  final today = DateTime(2026, 10, 27);
  final yesterday = DateTime(2026, 10, 26);
  final lastWeek = DateTime(2026, 10, 20);

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    repo = TaskRepository(db);
    store = TaskStore(repo, SettingsRepository(db));
  });

  group('查询', () {
    test('只取更早且未完成的', () async {
      await repo.insert(title: '昨天没做', day: yesterday);
      await repo.insert(title: '今天', day: today);
      await repo.insert(title: '明天', day: today.add(const Duration(days: 1)));
      final doneId = await repo.insert(title: '昨天做完了', day: yesterday);
      await repo.setDone(doneId, true);

      final overdue = await repo.overdueBefore(today);

      expect(overdue.map((t) => t.title), <String>['昨天没做']);
    });

    test('越近的排越前面', () async {
      await repo.insert(title: '上周的', day: lastWeek);
      await repo.insert(title: '昨天的', day: yesterday);

      final overdue = await repo.overdueBefore(today);
      expect(overdue.map((t) => t.title), <String>['昨天的', '上周的']);
    });

    test('带标签，卡片上要能显示', () async {
      await repo.insertTag(const Tag(id: 0, name: '工作'));
      final tagId = (await repo.allTags()).single.id;
      await repo.insert(title: '带标签的', day: yesterday, tagIds: <int>[tagId]);

      final overdue = await repo.overdueBefore(today);
      expect(overdue.single.tags.single.name, '工作');
    });

    test('limit 生效（逾期可能很多，不能一次全拉）', () async {
      for (var i = 0; i < 5; i++) {
        await repo.insert(title: '第 $i 条', day: yesterday);
      }
      expect(await repo.overdueBefore(today, limit: 2), hasLength(2));
    });
  });

  group('状态层', () {
    test('load 时一起带上逾期', () async {
      await repo.insert(title: '漏掉的', day: yesterday);
      await store.load(today);

      expect(store.tasks, isEmpty);
      expect(store.overdue.map((t) => t.title), <String>['漏掉的']);
    });

    test('标签筛选也作用在逾期上（筛"工作"不该冒出"学习"的逾期）', () async {
      await repo.insertTag(const Tag(id: 0, name: '工作'));
      await repo.insertTag(const Tag(id: 0, name: '学习'));
      final tags = await repo.allTags();
      final work = tags.firstWhere((t) => t.name == '工作').id;

      await repo.insert(title: '工作逾期', day: yesterday, tagIds: <int>[work]);
      await repo.insert(title: '学习逾期', day: yesterday);
      await store.load(today);

      expect(store.overdue, hasLength(2));
      store.setTagFilter('工作');
      expect(store.overdue.map((t) => t.title), <String>['工作逾期']);
    });

    test('移到这天：从逾期里消失，出现在当天列表', () async {
      await repo.insert(title: '要挪的', day: yesterday);
      await store.load(today);

      await store.moveToDay(store.overdue.single, today);

      expect(store.overdue, isEmpty);
      expect(store.tasks.map((t) => t.title), <String>['要挪的']);
      // 库里日期真的变了
      expect((await repo.tasksOn(today)).single.title, '要挪的');
      expect(await repo.overdueBefore(today), isEmpty);
    });

    test('全部移到这天：返回条数并清空逾期', () async {
      await repo.insert(title: 'a', day: yesterday);
      await repo.insert(title: 'b', day: lastWeek);
      await store.load(today);

      final moved = await store.moveAllOverdueTo(today);

      expect(moved, 2);
      expect(store.overdue, isEmpty);
      expect(store.tasks, hasLength(2));
    });

    test('没有逾期时全部移动返回 0，不做无意义写库', () async {
      await store.load(today);
      expect(await store.moveAllOverdueTo(today), 0);
    });
  });

  group('首页展示', () {
    Future<void> pump(WidgetTester tester, {
      required List<Task> overdue,
      List<Task> tasks = const <Task>[],
      VoidCallback? onMove,
    }) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: V6HomePage(
            selected: today,
            tasks: tasks,
            overdue: overdue,
            onMoveOverdueToSelectedDay: onMove,
            tags: const <Tag>[],
            onSelectDate: (_) {},
            onToggle: (_) {},
            onBeforeDelete: (_) async => false,
            onDeleted: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Task task(String title, DateTime day) => Task(
          id: title.hashCode.abs(),
          title: title,
          dueDate: day,
          priority: 'white',
          isDone: false,
        );

    testWidgets('有逾期时显示条数，卡片标出逾期几天', (tester) async {
      await pump(tester, overdue: <Task>[task('昨天的', yesterday)]);

      expect(find.text('逾期 1 条'), findsOneWidget);
      expect(find.text('逾期 1 天'), findsOneWidget);
      expect(find.text('昨天的'), findsOneWidget);
    });

    testWidgets('超过 3 条只摆 3 条，其余给一句提示', (tester) async {
      final overdue = <Task>[
        for (var i = 0; i < 5; i++) task('任务 $i', yesterday),
      ];
      await pump(tester, overdue: overdue);

      expect(find.text('逾期 5 条'), findsOneWidget);
      expect(find.textContaining('另有 2 条更早的'), findsOneWidget);
    });

    testWidgets('点「全部移到这天」会回调', (tester) async {
      var called = 0;
      await pump(
        tester,
        overdue: <Task>[task('昨天的', yesterday)],
        onMove: () => called++,
      );

      await tester.tap(find.text('全部移到这天'));
      await tester.pumpAndSettle();
      expect(called, 1);
    });

    testWidgets('逾期和当天都有时，当天那块有分隔标题', (tester) async {
      await pump(
        tester,
        overdue: <Task>[task('昨天的', yesterday)],
        tasks: <Task>[task('今天的', today)],
      );

      expect(find.text('当天'), findsOneWidget);
      expect(find.text('今天的'), findsOneWidget);
    });

    testWidgets('只有逾期、当天为空：不显示空状态', (tester) async {
      await pump(tester, overdue: <Task>[task('昨天的', yesterday)]);

      expect(find.text('这一天还没有任务'), findsNothing,
          reason: '有逾期任务就不算"这一天什么都没有"');
    });
  });
}
