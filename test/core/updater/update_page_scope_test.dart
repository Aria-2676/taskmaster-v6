// 「关于」→ 版本页这条路径的回归测试。
//
// 这里锁的是一个**只在运行时才暴露的 bug**：`AppUpdateProvider` 如果包在
// `MaterialApp.home` 里，`Navigator.push` 出来的路由就读不到它 ——
// 因为路由挂在 Navigator 下，而 Navigator 在 MaterialApp 内部，
// 那些页面的祖先链里没有 home 子树。表现是点「关于」直接红屏
// `ProviderNotFoundException`，而所有单元测试都还是绿的。
//
// 所以这条测试必须走真实结构：pump V6PreviewApp → 点我的 → 点关于。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/app/v6_preview_app.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';
import 'package:v5_app/core/updater/providers/app_update_provider.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskStore store;

  setUp(() async {
    SlotRegistry.instance.clear();
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    store = TaskStore(TaskRepository(db), SettingsRepository(db));
    await store.load();
  });

  tearDown(() => SlotRegistry.instance.clear());

  testWidgets('从「关于」进入版本页：Provider 在 MaterialApp 外，push 的页面读得到',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 注入的 provider 不 initialize：测试绝不联网
    final provider = AppUpdateProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      V6PreviewApp(
        store: store,
        autoSeed: false,
        injectedUpdate: provider,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '不能再出现 ProviderNotFoundException');
    // 版本页的标题（V6 传的是"关于"）
    expect(find.widgetWithText(AppBar, '关于'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('没有更新器时，「关于」不出现可点入口（避免点进去崩）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(V6PreviewApp(store: store, autoSeed: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    expect(find.text('关于页未接入（没有更新器）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
