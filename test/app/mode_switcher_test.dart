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
import 'package:v5_app/app/pages/home_mode_page.dart';
import 'package:v5_app/app/shell/main_shell.dart';
import 'package:v5_app/app/state/home_mode_store.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/app/widgets/mode_switcher.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';
import 'package:v5_app/core/home/home_mode.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
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

      expect(find.text('快捷切换'), findsOneWidget);
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

  // 弹层里到底列哪几个。默认值来自插件自己的声明（manifest 的 `home`）：
  // 声明了 = 默认开（它是"模式插件"），没声明 = 默认关（仍可当首页，用户自己开）。
  group('快捷切换的取舍', () {
    List<ModeOption> optionsOf(List<String> ids) => buildModeOptions(
          plugins: <InstalledPlugin>[for (final id in ids) fakeInstalled(id)],
          nameOf: (id) => id,
        );

    test('全开时一个不落', () {
      final list = quickOptions(
        optionsOf(<String>['a', 'b']),
        visibleOf: (_) => true,
        current: const HomeMode.builtin(),
      );
      expect(list.length, 3);
    });

    test('用户收起的不出现，内置永远在', () {
      final list = quickOptions(
        optionsOf(<String>['a', 'b']),
        visibleOf: (o) => o.pluginId != 'b',
        current: const HomeMode.builtin(),
      );
      expect(list.map((o) => o.pluginId), <String?>[null, 'a']);
    });

    test('当前模式被收起也要出现（旧数据兜底）', () {
      final list = quickOptions(
        optionsOf(<String>['a', 'b']),
        visibleOf: (o) => o.pluginId != 'a',
        current: const HomeMode.plugin('a'),
      );
      expect(list.map((o) => o.pluginId), contains('a'));
    });

    test('内置被收起也要出现（插件崩了只能靠它回去）', () {
      final list = quickOptions(
        optionsOf(<String>['a']),
        visibleOf: (_) => false,
        current: const HomeMode.plugin('a'),
      );
      expect(list.first.isBuiltin, isTrue);
    });
  });

  // 声明只决定两件事：默认开不开、显示什么名字。
  group('模式声明', () {
    List<ModeOption> optionsOf(
      List<String> ids, {
      Set<String> declared = const <String>{},
      PluginHomeSpec? Function(String)? homeOf,
    }) {
      return buildModeOptions(
        plugins: <InstalledPlugin>[for (final id in ids) fakeInstalled(id)],
        nameOf: (id) => '插件$id',
        homeOf: homeOf ??
            (id) => declared.contains(id)
                ? PluginHomeSpec(label: '模式$id', hint: '一句话')
                : null,
      );
    }

    test('声明了 home：用 label 当名字、hint 当副标题、默认进快捷切换', () {
      final option = optionsOf(<String>['plan'], declared: <String>{'plan'})[1];
      expect(option.name, '模式plan');
      expect(option.subtitle, '一句话');
      expect(option.defaultQuick, isTrue);
    });

    test('没声明：名字退回插件名，默认不进快捷切换', () {
      final option = optionsOf(<String>['journal'])[1];
      expect(option.name, '插件journal');
      expect(option.subtitle, contains('插件整页'));
      expect(option.defaultQuick, isFalse);
    });

    test('声明了的排在前面，按 order 升序；没声明的保持安装顺序', () {
      final list = optionsOf(
        <String>['journal', 'late', 'early', 'demo'],
        homeOf: (id) => switch (id) {
          'late' => const PluginHomeSpec(label: '晚', order: 30),
          'early' => const PluginHomeSpec(label: '早', order: 10),
          _ => null,
        },
      );
      expect(
        list.map((o) => o.pluginId),
        <String?>[null, 'early', 'late', 'journal', 'demo'],
      );
    });

    test('"home": true 这种最省事的写法也认（默认 100）', () {
      final list = optionsOf(
        <String>['plan'],
        homeOf: (_) => PluginHomeSpec.bare,
      );
      expect(list[1].defaultQuick, isTrue);
      expect(list[1].order, 100);
    });
  });

  group('快捷项管理', () {
    late Database db;
    late SettingsRepository settings;
    late HomeModeStore store;
    final plan = const HomeMode.plugin('plan');

    setUp(() async {
      db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      addTearDown(db.close);
      settings = SettingsRepository(db);
      store = HomeModeStore(settings);
      await store.load();
    });

    test('没动过手就跟随默认值', () {
      expect(store.isQuickVisible(plan, defaultOn: true), isTrue);
      expect(store.isQuickVisible(plan, defaultOn: false), isFalse);
    });

    test('收起一个默认开启的：落库，重建仍收起', () async {
      await store.setQuickVisible(plan, false, defaultOn: true);
      expect(store.isQuickVisible(plan, defaultOn: true), isFalse);

      final again = HomeModeStore(settings);
      await again.load();
      expect(again.isQuickVisible(plan, defaultOn: true), isFalse);
    });

    test('打开一个默认关闭的：落库，重建仍打开', () async {
      await store.setQuickVisible(plan, true, defaultOn: false);

      final again = HomeModeStore(settings);
      await again.load();
      expect(again.isQuickVisible(plan, defaultOn: false), isTrue);
    });

    test('改回默认值会把记录删掉（插件以后改默认值才跟得上）', () async {
      await store.setQuickVisible(plan, false, defaultOn: true);
      await store.setQuickVisible(plan, true, defaultOn: true);

      expect(await settings.get(SettingsKeys.homeQuickOverrides), isEmpty);

      final again = HomeModeStore(settings);
      await again.load();
      expect(again.isQuickVisible(plan, defaultOn: false), isFalse,
          reason: '记录删干净了，就该完全听默认值');
    });

    test('内置与当前模式改不动', () async {
      await store.setQuickVisible(const HomeMode.builtin(), false, defaultOn: true);
      expect(store.isQuickVisible(const HomeMode.builtin(), defaultOn: true), isTrue);

      await store.setMode(plan);
      await store.setQuickVisible(plan, false, defaultOn: true);
      expect(
        store.isQuickVisible(plan, defaultOn: true),
        isTrue,
        reason: '当前模式必须在列表里，否则点开看不出自己在哪儿',
      );
    });

    test('卸载插件清掉记录', () async {
      await store.setQuickVisible(plan, false, defaultOn: true);
      await store.onPluginUninstalled('plan');

      final again = HomeModeStore(settings);
      await again.load();
      expect(again.isQuickVisible(plan, defaultOn: true), isTrue,
          reason: '重装同名插件时该按新默认来，不该继承旧记录');
    });

    test('从 6.0.4 的「收起集合」迁移：以前关掉的仍关着', () async {
      await settings.set(SettingsKeys.homeQuickHidden, 'plugin:journal,plugin:plan');

      final migrated = HomeModeStore(settings);
      await migrated.load();

      expect(migrated.isQuickVisible(HomeMode.plugin('plan'), defaultOn: true), isFalse);
      expect(migrated.isQuickVisible(HomeMode.plugin('journal'), defaultOn: false), isFalse);
    });
  });

  group('首页模式页的快捷开关', () {
    late Database db;
    late HomeModeStore store;

    setUp(() async {
      db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      addTearDown(db.close);
      store = HomeModeStore(SettingsRepository(db));
      await store.load();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeModePage(
            store: store,
            plugins: <InstalledPlugin>[
              fakeInstalled('plan'),
              fakeInstalled('journal'),
            ],
            nameOf: (id) => id == 'plan' ? '周计划' : '记账',
            homeOf: (id) => id == 'plan'
                ? const PluginHomeSpec(label: '计划模式', hint: '未来七天铺开')
                : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('声明了 home 的默认开，没声明的默认关', (tester) async {
      await pumpPage(tester);

      final plan =
          tester.widget<Switch>(find.byKey(const Key('mode-quick-plugin:plan')));
      final journal = tester
          .widget<Switch>(find.byKey(const Key('mode-quick-plugin:journal')));

      expect(plan.value, isTrue, reason: '模式插件默认进快捷切换');
      expect(journal.value, isFalse, reason: '页面插件默认收起，但用户可以打开');
      expect(find.text('计划模式'), findsOneWidget);
      expect(find.text('未来七天铺开'), findsOneWidget);
    });

    testWidgets('内置那行开关禁用且恒开', (tester) async {
      await pumpPage(tester);

      final builtin =
          tester.widget<Switch>(find.byKey(const Key('mode-quick-builtin')));
      expect(builtin.value, isTrue);
      expect(builtin.onChanged, isNull, reason: '内置是插件崩了之后的退路');
    });

    testWidgets('关掉模式插件那一行会落状态', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('mode-quick-plugin:plan')));
      await tester.pumpAndSettle();

      expect(
        store.isQuickVisible(const HomeMode.plugin('plan'), defaultOn: true),
        isFalse,
      );
    });

    testWidgets('当前模式那行开关禁用', (tester) async {
      await store.setMode(const HomeMode.plugin('journal'));
      await pumpPage(tester);

      final current = tester
          .widget<Switch>(find.byKey(const Key('mode-quick-plugin:journal')));
      expect(current.value, isTrue);
      expect(current.onChanged, isNull);
    });
  });
}
