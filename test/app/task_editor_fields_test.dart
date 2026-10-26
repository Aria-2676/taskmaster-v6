// 编辑页的字段驱动 + 形态。
//
// 盯四件事：
//   1. 默认从底部弹层打开（不是全屏页）
//   2. 字段管理里关掉的字段，编辑页真的不画
//   3. 默认值只预填显示，**没动过的字段保存时仍是 null**
//   4. 被藏起来但有内容的字段要提示，不能让人觉得数据没了

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/editor_form.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/pages/task_editor_page.dart';
import 'package:v5_app/app/state/field_store.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/field/task_field.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;
  late TaskStore store;
  late FieldStore fields;
  late DateTime day;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);

    final settings = SettingsRepository(db);
    repo = TaskRepository(db);
    store = TaskStore(repo, settings);
    fields = FieldStore(settings);
    await fields.load();

    final now = DateTime.now();
    day = DateTime(now.year, now.month, now.day);
    await store.load(day);
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(
    WidgetTester tester, {
    Task? task,
    EditorForm? form,
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
                onPressed: () => showTaskEditor(
                  context,
                  store: store,
                  fields: fields,
                  task: task,
                  initialDay: day,
                  form: form,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await settle(tester);
  }

  testWidgets('默认是底部弹层，不是全屏页', (tester) async {
    await openEditor(tester);

    expect(find.text('新建任务'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    // 全屏页才有的 AppBar；弹层不能有
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('显式选全屏时，回到带 AppBar 的整页', (tester) async {
    await openEditor(tester, form: EditorForm.full);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });

  testWidgets('关掉「预计时长」后，编辑页不再画这一项', (tester) async {
    await fields.setVisible(FieldCatalog.minutes.id, false);
    await openEditor(tester);

    expect(find.text('预计时长'), findsNothing);
    expect(find.text('不设'), findsNothing);
    expect(find.text('优先级'), findsOneWidget, reason: '没关的字段要留着');
  });

  testWidgets('被关掉但已有内容的字段要提示，不能让它凭空消失', (tester) async {
    await repo.insert(title: '写周报', day: day, description: '本周进展');
    await store.load(day);
    await fields.setVisible(FieldCatalog.description.id, false);

    await openEditor(tester, task: store.tasks.single);

    expect(find.widgetWithText(TextField, '本周进展'), findsNothing);
    expect(find.textContaining('已隐藏 描述'), findsOneWidget);
  });

  testWidgets('点提示可以把藏起来的内容临时展开', (tester) async {
    await repo.insert(title: '写周报', day: day, description: '本周进展');
    await store.load(day);
    await fields.setVisible(FieldCatalog.description.id, false);

    await openEditor(tester, task: store.tasks.single);
    await tester.tap(find.textContaining('已隐藏 描述'));
    await settle(tester);

    expect(find.widgetWithText(TextField, '本周进展'), findsOneWidget);
  });

  testWidgets('默认值在新建时落库：设了默认 60，新任务就是 60', (tester) async {
    await fields.setDefault(FieldCatalog.minutes.id, '60');
    await openEditor(tester);

    // 界面上显示 60，并且标了「默认」
    expect(find.text('60 分钟'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.text('添加'));
    await settle(tester);

    final created = (await repo.tasksOn(day)).single;
    expect(created.title, '买牛奶');
    expect(created.estimatedMinutes, 60,
        reason: '只预填不落库，卡片上不显示时长，用户会认为"默认设置没生效"');
  });

  testWidgets('默认值不回填已有任务：编辑时没动过，库里仍是 null', (tester) async {
    await repo.insert(title: '旧任务', day: day);
    await store.load(day);
    await fields.setDefault(FieldCatalog.minutes.id, '60');

    await openEditor(tester, task: store.tasks.single);
    await tester.tap(find.text('保存'));
    await settle(tester);

    final saved = (await repo.tasksOn(day)).single;
    expect(saved.estimatedMinutes, isNull,
        reason: '改默认值不该顺手改写历史数据');
  });

  testWidgets('用户真的选了时长，才写进库', (tester) async {
    await fields.setDefault(FieldCatalog.minutes.id, '60');
    await openEditor(tester);

    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.text('15 分钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await settle(tester);

    expect((await repo.tasksOn(day)).single.estimatedMinutes, 15);
  });

  testWidgets('默认优先级预填为橙，保存时按用户看到的写', (tester) async {
    await fields.setDefault(FieldCatalog.priority.id, 'orange');
    await openEditor(tester);

    expect(find.text('默认'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.text('添加'));
    await settle(tester);

    expect((await repo.tasksOn(day)).single.priority, 'orange');
  });

  testWidgets('有改动时点 X：先问「放弃修改？」', (tester) async {
    await openEditor(tester);

    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);

    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await settle(tester);
    expect(find.text('新建任务'), findsOneWidget, reason: '选继续编辑就不该退出');

    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    await tester.tap(find.text('放弃'));
    await settle(tester);

    expect(await repo.tasksOn(day), isEmpty, reason: '放弃不等于保存');
  });

  testWidgets('设置里把形态切成全屏，新建时就是整页', (tester) async {
    await store.setEditorForm(EditorForm.full);
    await openEditor(tester);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });

  testWidgets('往下拖不会把弹层拖没（否则等于无声放弃修改）', (tester) async {
    await openEditor(tester);
    await tester.enterText(find.byType(TextField).first, '改了一半');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 420));
    await tester.pumpAndSettle();

    // 真机上这里曾经直接 pop 掉整个弹层（DraggableScrollableSheet 默认
    // shouldCloseOnMinExtent = true），用户改到一半一拉就没了，连确认都不问
    expect(find.text('新建任务'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
  });

  testWidgets('关掉字段不影响已有数据：再打开，值还在', (tester) async {
    await repo.insert(title: '写周报', day: day, estimatedMinutes: 30);
    await store.load(day);

    await fields.setVisible(FieldCatalog.minutes.id, false);
    await fields.setVisible(FieldCatalog.minutes.id, true);

    await openEditor(tester, task: store.tasks.single);
    expect(find.text('30 分钟'), findsOneWidget);
  });
}
