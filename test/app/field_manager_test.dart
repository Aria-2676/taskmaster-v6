// 字段管理页的交互测试。
//
// 这一页的行为（开关、改默认值、恢复默认）全都能在测试里判定，
// 不该占用用户的验收时间 —— 用户只该判断"手感/好不好看"这类机器判不了的事。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/pages/field_manager_page.dart';
import 'package:v5_app/app/state/field_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/field/task_field.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late FieldStore fields;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    fields = FieldStore(SettingsRepository(db));
    await fields.load();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: FieldManagerPage(store: fields)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('六行字段都在，锁定字段没有开关', (tester) async {
    await open(tester);

    for (final field in FieldCatalog.all) {
      expect(find.text(field.label), findsOneWidget, reason: '缺少字段：${field.label}');
    }
    // 标题、日期锁定 → 只有四个开关
    expect(find.byType(Switch), findsNWidgets(4));
    expect(find.text('必填'), findsNWidgets(2));
    expect(find.text('核心'), findsNWidgets(2));
  });

  testWidgets('拨开关会真的改偏好，并且能再拨回来', (tester) async {
    await open(tester);

    // 开关顺序 = 非锁定字段的目录顺序：优先级 / 标签 / 描述 / 预计时长
    await tester.tap(find.byType(Switch).at(3));
    await tester.pumpAndSettle();
    expect(fields.isHidden(FieldCatalog.minutes.id), isTrue);

    await tester.tap(find.byType(Switch).at(3));
    await tester.pumpAndSettle();
    expect(fields.isHidden(FieldCatalog.minutes.id), isFalse);
  });

  testWidgets('点一行能改默认值，副标题跟着变', (tester) async {
    await open(tester);

    expect(find.text('默认：不设'), findsOneWidget);
    await tester.tap(find.text('默认：不设'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('60 分钟').last);
    await tester.pumpAndSettle();

    expect(fields.defaultOf(FieldCatalog.minutes), '60');
    expect(find.text('默认：60 分钟'), findsOneWidget);
  });

  testWidgets('恢复默认：二次确认后开关和默认值都回出厂', (tester) async {
    await fields.setVisible(FieldCatalog.minutes.id, false);
    await fields.setDefault(FieldCatalog.priority.id, 'orange');
    await open(tester);

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(fields.isHidden(FieldCatalog.minutes.id), isFalse);
    expect(fields.defaultOf(FieldCatalog.priority), 'white');
    expect(find.text('默认：白'), findsOneWidget);
  });

  testWidgets('锁定字段就算从 JSON 里读到 hidden 也不会真的关掉', (tester) async {
    await open(tester);

    // 界面上根本没有它的开关，能点的只有四个
    expect(find.byType(Switch), findsNWidgets(4));
    expect(fields.isHidden(FieldCatalog.title.id), isFalse);
  });
}
