// 插件停用 / 启用（**完全停机**）。
//
// 停用的语义定案：入口消失 + 不再投递事件 + 不占首页和货币位，
// 但**不动数据** —— 这是它和卸载的唯一区别。
//
// 这个文件只测"状态与投递"，界面上的入口过滤由 main_shell 的
// `market.active` 保证（同样的判据，不必在 widget 测试里再点一遍）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_bridge.dart';
import 'package:v5_app/app/data/plugin_index_loader.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/pages/plugin_market_page.dart';
import 'package:v5_app/app/state/currency_store.dart';
import 'package:v5_app/app/state/plugin_market_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_installer.dart';
import 'package:v5_app/core/plugin/plugin_store.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tempRoot;
  late Database db;
  late SettingsRepository settings;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('v6_disabled_');
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    settings = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  /// 直接把一条安装记录写进库 —— 停用/启用只碰这一行，
  /// 不需要真的解压一个包（那条链路在 plugin_market_test 里已经验过）。
  Future<void> installFake(String pluginId) async {
    final store = PluginStore(db);
    await store.upsert(InstalledPlugin(
      pluginId: pluginId,
      version: '1.0.0',
      contract: 1,
      installDir: '$pluginId/1.0.0',
      installedAt: DateTime(2026, 10, 28),
    ));
  }

  PluginMarketStore buildStore({
    void Function(String pluginId, bool enabled)? onEnabledChanged,
  }) =>
      PluginMarketStore(
        installer: PluginInstaller(
          db: db,
          rootDir: Directory(p.join(tempRoot.path, 'plugins')),
          schemas: PluginSchemaRegistry(),
          fetch: ({
            required Uri url,
            required String destPath,
            void Function(int received, int? total)? onProgress,
          }) async {},
        ),
        // 索引读不读得到与停用无关，这里给个空索引
        indexLoader: () async => PluginIndexResult.bundled(PluginIndex.empty),
        urlFor: (pkg) => Uri.file(pkg.path),
        onEnabledChanged: onEnabledChanged,
      );

  group('状态', () {
    test('停用后：已安装里仍在，但对外可见列表里没有它', () async {
      await installFake('demo_help');
      final store = buildStore();
      await store.refresh();
      expect(store.active.map((p) => p.pluginId), <String>['demo_help']);

      await store.setEnabled('demo_help', false);

      // 市场页要用 installed（看得见才能开回来）
      expect(store.installed.single.pluginId, 'demo_help');
      expect(store.installed.single.enabled, isFalse);
      // 外壳用 active（入口 / 首页 / 货币位都从这里取）
      expect(store.active, isEmpty);
    });

    test('启用回来：重新出现在 active 里，且记下启用时刻', () async {
      await installFake('demo_help');
      final store = buildStore();
      await store.refresh();
      await store.setEnabled('demo_help', false);
      expect(await settings.get(SettingsKeys.pluginEnabledAt('demo_help')), isNull,
          reason: '停用时不该写启用时刻');

      await store.setEnabled('demo_help', true);

      expect(store.active.single.pluginId, 'demo_help');
      final stamp = await settings.get(SettingsKeys.pluginEnabledAt('demo_help'));
      expect(stamp, isNotNull);
      // 能被解析成时间（桥拿它做时间比较，格式错了会静默失效）
      expect(DateTime.tryParse(stamp!), isNotNull);
    });

    test('每次停用/启用都把变化通知给应用层（否则首页和货币位不会回落）', () async {
      await installFake('demo_help');
      final calls = <String>[];
      final store = buildStore(
        onEnabledChanged: (id, enabled) => calls.add('$id:$enabled'),
      );
      await store.refresh();

      await store.setEnabled('demo_help', false);
      await store.setEnabled('demo_help', true);

      expect(calls, <String>['demo_help:false', 'demo_help:true']);
    });
  });

  group('事件：停用期间不攒', () {
    /// 造一个声明了 task.completed 的桥
    PluginBridge bridgeFor(EventJournal journal) => PluginBridge(
          pluginId: 'energy',
          version: '1.0.0',
          permissions: const <String>{'task:read'},
          tasks: TaskRepository(db),
          settings: settings,
          contract: 1,
          hooks: const <HookId>{HookId.taskCompleted},
          journal: journal,
        );

    test('启用之前记录的事件不投递；启用之后记录的才投递', () async {
      final journal = EventJournal(db);
      // 停用期间攒下的一条（用户看不到时间，但库里已经写了一条）
      await journal.record(const HookEvent(
        hook: HookId.taskCompleted,
        payload: <String, Object?>{'title': '停用期间完成的'},
      ));
      // 时间戳只到毫秒，隔开一点免得和"启用时刻"打平
      await Future<void>.delayed(const Duration(milliseconds: 8));

      // 用户点了「启用」
      await settings.set(
        SettingsKeys.pluginEnabledAt('energy'),
        DateTime.now().toUtc().toIso8601String(),
      );
      await journal.record(const HookEvent(
        hook: HookId.taskCompleted,
        payload: <String, Object?>{'title': '启用之后完成的'},
      ));

      final response = await bridgeFor(journal)
          .dispatch('event.pending', const <String, Object?>{});

      final list = List<Object?>.from(response['result']! as List);
      expect(list, hasLength(1), reason: '停用期间那条不该补发');
      final event = Map<String, Object?>.from(list.single! as Map);
      expect(
        Map<String, Object?>.from(event['payload']! as Map)['title'],
        '启用之后完成的',
      );
    });

    test('从没停用过（没有启用时刻）：照旧全投，不误伤老插件', () async {
      final journal = EventJournal(db);
      await journal.record(const HookEvent(
        hook: HookId.taskCompleted,
        payload: <String, Object?>{'title': '装上就有的'},
      ));

      final response = await bridgeFor(journal)
          .dispatch('event.pending', const <String, Object?>{});

      expect(List<Object?>.from(response['result']! as List), hasLength(1));
    });
  });

  group('货币位', () {
    test('库里存的是空串（"不要货币"）时，插件重新报余额也能抢回货币位', () async {
      // 真机上就是栽在这：空串没归一化成 null，于是"有货币但 id 为空"，
      // report 里 `_providerId == null` 永远为假 → 停用再启用徽章不回来。
      await settings.set(SettingsKeys.activeCurrency, '');
      final currency = CurrencyStore(settings);
      await currency.load();
      expect(currency.providerId, isNull, reason: '空串必须当成"没有货币"');
      expect(currency.installed, isFalse);

      await currency.report('energy', 10);

      expect(currency.providerId, 'energy');
      expect(currency.balance, 10);
    });

    test('停用撤下货币位，启用按旧余额接回（不清零）', () async {
      final currency = CurrencyStore(settings);
      await currency.load();
      await currency.report('energy', 10);
      expect(currency.providerId, 'energy');
      expect(currency.balance, 10);

      // 停用：应用层走的是这条（和卸载同一个方法）
      await currency.onPluginUninstalled('energy');
      expect(currency.providerId, isNull);
      expect(currency.balance, 0);
      expect(await settings.get(SettingsKeys.activeCurrency), '');

      // 启用：按镜像里的旧余额接回
      await currency.resumeAfterEnable('energy', providesCurrency: true);
      expect(currency.providerId, 'energy');
      expect(currency.balance, 10, reason: '停用不该动余额');
    });

    test('没声明 currency:write 的插件，启用时不会被错认成货币提供者', () async {
      final currency = CurrencyStore(settings);
      await currency.load();

      await currency.resumeAfterEnable('demo_help', providesCurrency: false);

      expect(currency.providerId, isNull,
          reason: 'ensureProvider 会写 0，所以判据必须是权限声明而不是"有没有镜像"');
    });

    test('声明了 currency:write 但还没报过余额：启用也要占住货币位', () async {
      // 真机上漏过这一条：原来用"有没有余额镜像"当判据，
      // 而镜像要插件报过一次余额才存在 —— 装完没打开过就永远不亮徽章。
      final currency = CurrencyStore(settings);
      await currency.load();
      expect(await settings.get(SettingsKeys.currencyBalance('energy')), isNull);

      await currency.resumeAfterEnable('energy', providesCurrency: true);

      expect(currency.providerId, 'energy');
      expect(currency.balance, 0);
    });
  });

  group('市场页', () {
    /// 等真实异步（sqflite 的读库）落地。假时钟推不动它，必须 runAsync。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
    }

    testWidgets('拨开关 → 副标题出现「已停用」，条目照旧留着', (tester) async {
      await installFake('demo_help');
      final store = buildStore();
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      // 没有索引时标题回落到插件 id
      expect(find.text('demo_help'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.textContaining('已停用'), findsNothing);

      await tester.tap(find.byType(Switch));
      await settle(tester);

      // 关键：条目没消失（市场页用 installed），但状态写清楚了
      expect(find.text('demo_help'), findsOneWidget);
      // 断言整行副标题而不是 contains：提示条里也有「已停用」三个字
      expect(find.text('v1.0.0 · 契约 1 · 已停用'), findsOneWidget);
      expect(store.active, isEmpty, reason: '外壳这时候应该看不到它了');
    });
  });
}
