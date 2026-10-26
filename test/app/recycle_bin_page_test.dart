// 回收站页面的契约测试。
//
// 这一页只有三个动作：恢复、彻底删除、清空。
// 三个动作都会真的改数据，所以断言一律**看库**，不看界面文字是否消失。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/pages/recycle_bin_page.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    repo = TaskRepository(db);
  });

  /// 写库之后要等数据真的落定：`pump` 只推帧，不等 IO
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpPage(WidgetTester tester, {VoidCallback? onChanged}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: RecycleBinPage(
          repository: repo,
          retentionDays: 7,
          onChanged: onChanged,
        ),
      ),
    );
    await settle(tester);
  }

  /// 造一条回收站记录
  Future<void> seedRecycled(
    String title, {
    int daysAgo = 0,
    List<int> tagIds = const <int>[],
  }) async {
    final day = DateTime.now();
    final id = await repo.insert(title: title, day: day, tagIds: tagIds);
    await repo.moveToRecycle(id);
    if (daysAgo > 0) {
      await db.update(
        'recycled_tasks',
        <String, Object?>{
          'deleted_at': DateTime.now()
              .toUtc()
              .subtract(Duration(days: daysAgo))
              .toIso8601String(),
        },
        where: 'title = ?',
        whereArgs: <Object?>[title],
      );
    }
  }

  testWidgets('空回收站显示空状态，且不显示「清空」', (tester) async {
    await pumpPage(tester);

    expect(find.text('回收站是空的'), findsOneWidget);
    expect(find.text('清空'), findsNothing, reason: '空的时候不该给一个没用的按钮');
    expect(find.textContaining('保留 7 天'), findsOneWidget);
  });

  testWidgets('有内容时显示标题与剩余天数', (tester) async {
    await seedRecycled('误删的任务', daysAgo: 5);
    await pumpPage(tester);

    expect(find.text('误删的任务'), findsOneWidget);
    expect(find.textContaining('2 天后清理'), findsOneWidget, reason: '7 天保留、已过 5 天');
  });

  testWidgets('打开页面时会先清掉已过期的条目', (tester) async {
    // 10 天前删的、保留 7 天 —— 早就该没了。
    // 清理没有后台定时器，所以"进页面"是必须清理的机会点之一；
    // 不清的话这里会显示一条「即将清理」却永远在那儿的记录。
    await seedRecycled('早该清的', daysAgo: 10);
    await pumpPage(tester);

    expect(await repo.recycledCount(), 0, reason: '进页面就应该清掉');
    expect(find.text('早该清的'), findsNothing);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('列表里显示标签，方便判断恢复后是什么样', (tester) async {
    await repo.insertTag(const Tag(id: 0, name: '工作'));
    final tag = (await repo.allTags()).single;
    await seedRecycled('带标签的任务', tagIds: <int>[tag.id]);

    await pumpPage(tester);

    expect(find.text('带标签的任务'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget, reason: '回收站里要能看见标签');
  });

  testWidgets('点「恢复」：任务回到任务表，回收站清空，并通知外层刷新', (tester) async {
    await seedRecycled('救回来的任务');
    var notified = 0;
    await pumpPage(tester, onChanged: () => notified++);

    await tester.tap(find.text('恢复'));
    await settle(tester);

    expect(await repo.recycledCount(), 0);
    final tasks = await repo.tasksOn(DateTime.now());
    expect(tasks.map((t) => t.title), contains('救回来的任务'));
    expect(notified, 1, reason: '首页要能立刻看到恢复的任务');
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('点彻底删除：库里没有这一条了', (tester) async {
    await seedRecycled('彻底删掉');
    await pumpPage(tester);

    await tester.tap(find.byTooltip('彻底删除'));
    await settle(tester);

    expect(await repo.recycledCount(), 0);
    expect(await repo.tasksOn(DateTime.now()), isEmpty, reason: '不该顺手把任务塞回去');
  });

  testWidgets('清空：先确认，确认后全部删掉', (tester) async {
    await seedRecycled('第一条');
    await seedRecycled('第二条');
    await pumpPage(tester);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    // 取消不删
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await repo.recycledCount(), 2);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    // 弹窗里的「清空」和 AppBar 上的同名，必须限定在对话框内点
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('清空')),
    );
    await settle(tester);

    expect(await repo.recycledCount(), 0);
  });
}
