// 模式切换：顶栏入口 + 选项清单 + 插件模式下收起 `+`。
//
// 盯三件事，它们都是"模式"这套东西能不能成立的前提：
//   1. 当前模式必须**一眼可见**（顶栏写的是什么）
//   2. 切换必须**随手可做**（顶栏箭头 → 弹层 → 选中即生效）
//   3. 插件模式下**不能留 `+`**（主包不知道插件里"新建"是什么）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/shell/main_shell.dart';
import 'package:v5_app/app/state/home_mode_store.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/app/widgets/mode_switcher.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';
import 'package:v5_app/core/home/home_mode.dart';
import 'package:v5_app/core/plugin/plugin_store.dart';

InstalledPlugin fakeInstalled(String id, {String version = '1.2.0'}) {
  return InstalledPlugin(
    pluginId: id,
    version: version,
    contract: 1,
    installDir: '/tmp/$id',
    installedAt: DateTime(2026, 10, 1),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('选项清单', () {
    test('内置永远排第一，插件跟在后面并带版本', () {
      final options = buildModeOptions(
        plugins: <InstalledPlugin>[
          fakeInstalled('journal', version: '0.3.1'),
          fakeInstalled('stats'),
        ],
        nameOf: (id) => id == 'journal' ? '日记' : '统计',
      );

      expect(options.length, 3);
      expect(options.first.isBuiltin, isTrue);
      expect(options.first.name, '任务模式');
      expect(options[1].pluginId, 'journal');
      expect(options[1].name, '日记');
      expect(options[1].subtitle, contains('0.3.1'));
      // 名字查不到时不能显示成空白
      expect(options[2].name, '统计');
    });

    test('没有插件时只有内置一项', () {
      final options = buildModeOptions(
        plugins: const <InstalledPlugin>[],
        nameOf: (id) => id,
      );
      expect(options.length, 1);
      expect(options.single.mode.isBuiltin, isTrue);
    });

    test('选项能还原成可持久化的模式', () {
      final plugin = buildModeOptions(
        plugins: <InstalledPlugin>[fakeInstalled('journal')],
        nameOf: (id) => id,
      )[1];
      expect(plugin.mode.encode(), 'plugin:journal');
      expect(HomeMode.parse(plugin.mode.encode()), plugin.mode);
    });
  });

  group('主壳顶栏', () {
    late Database db;
    late TaskStore store;
    late HomeModeStore home;

    setUp(() async {
      SlotRegistry.instance.clear();
      db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      store = TaskStore(TaskRepository(db), settings);
      await store.load();
      home = HomeModeStore(settings);
      await home.load();
    });

    tearDown(() => SlotRegistry.instance.clear());

    Future<void> pumpShell(WidgetTester tester, {WidgetBuilder? about}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            store: store,
            homeStore: home,
            aboutPageBuilder: about,
          ),
        ),
      );
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('内置模式：顶栏是日期，有 + 按钮', (tester) async {
      await pumpShell(tester);

      expect(find.byKey(const Key('v6-header-date')), findsOneWidget);
      expect(find.byKey(const Key('v6-header-mode')), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('插件模式：顶栏换成插件名，+ 按钮收起', (tester) async {
      await home.setMode(const HomeMode.plugin('demo_help'));
      // 主壳会自己响应 homeStore 的通知，不需要重新 pump
      await pumpShell(tester);

      expect(find.byKey(const Key('v6-header-mode')), findsOneWidget);
      expect(find.byKey(const Key('v6-header-date')), findsNothing);
      expect(
        find.byIcon(Icons.add),
        findsNothing,
        reason: '插件模式下留一个 + 会建出用户没预期的任务',
      );
    });

    testWidgets('点顶栏箭头 → 弹层列出模式，选中内置后顶栏回到日期', (tester) async {
      await home.setMode(const HomeMode.plugin('demo_help'));
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.unfold_more));
      await tester.pumpAndSettle();

      expect(find.text('当前模式'), findsOneWidget);
      expect(find.text('任务模式'), findsOneWidget);

      await tester.tap(find.text('任务模式'));
      await tester.pumpAndSettle();

      expect(home.mode.isBuiltin, isTrue, reason: '选中后必须真的落状态');
      expect(find.byKey(const Key('v6-header-date')), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    // 「关于」是更新的**唯一手动入口**：自动提示被跳过、被关掉之后，
    // 用户需要一个能自己按一下的地方，否则就彻底没有反悔的路径。
    testWidgets('关于：给了构造器就能打开', (tester) async {
      await pumpShell(
        tester,
        about: (_) => const Scaffold(body: Text('关于页占位')),
      );

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('关于'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.text('关于页占位'), findsOneWidget);
    });

    testWidgets('关于：没有更新器时只提示，不崩', (tester) async {
      await pumpShell(tester);

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
  });
}
