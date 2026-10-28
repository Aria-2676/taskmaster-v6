// 插件市场：状态层 + 页面。
//
// 索引用注入的 JSON，包用本地 zip + 复制式 fetcher —— 整条链路
// （下载 → sha256 → 解压 → 落位 → 登记 → 卸载）都在测试里真跑一遍，
// 只是不经过网络。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/pages/plugin_market_page.dart';
import 'package:v5_app/app/state/plugin_market_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_installer.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
import 'package:v5_app/core/services/file_downloader.dart';

/// 版本号参数化的索引（只含 demo_help 一项）
PluginIndex _indexWithVersion(String version, String sha) =>
    PluginIndex.parse(<String, Object?>{
      'schemaVersion': 1,
      'plugins': <Object?>[
        <String, Object?>{
          'id': 'demo_help',
          'name': '使用说明',
          'version': version,
          'contract': 1,
          'description': '验证安装链路的示例插件',
          'icon': 'help',
          'permissions': <String>['task:read', 'task:write'],
          'package': <String, Object?>{
            'path': 'assets/plugins/demo_help_v$version.zip',
            'sha256': sha,
            'sizeBytes': 1024,
          },
        },
      ],
    });

/// 版本号参数化的索引条目
PluginIndexEntry _entryWithVersion(String version, String sha) =>
    _indexWithVersion(version, sha).plugins.single;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tempRoot;
  late Directory pluginRoot;
  late Database db;
  late String shaValue;

  Future<void> fakeFetch({
    required Uri url,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) async {
    await File(url.toFilePath()).copy(destPath);
    onProgress?.call(1, 1);
  }

  /// 造一个与 assets 里那个示例插件同构的 zip。
  ///
  /// [withStorage] 让包内声明一张私有表 —— 卸载"保留数据/删数据"两条路
  /// 只有真的有表才验得出来。
  Future<String> buildZip({String version = '1.0.0', bool withStorage = false}) async {
    final archive = Archive();
    final manifest = utf8.encode(jsonEncode(<String, Object?>{
      'id': 'demo_help',
      'name': '使用说明',
      'version': version,
      'contract': 1,
      'entry': 'index.html',
      'icon': 'help',
      if (withStorage)
        'storage': <String, Object?>{
          'version': 1,
          'tables': <Object?>[
            <String, Object?>{
              'name': 'entries',
              'columns': <Object?>[
                <String, Object?>{'name': 'day', 'type': 'text', 'notNull': true},
                <String, Object?>{'name': 'minutes', 'type': 'integer'},
              ],
            },
          ],
        },
    }));
    final html = utf8.encode('<html><body>hi</body></html>');
    archive.addFile(ArchiveFile('plugin.json', manifest.length, manifest));
    archive.addFile(ArchiveFile('index.html', html.length, html));
    final file = File(p.join(tempRoot.path, 'demo_help_v$version.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return await FileDownloader.sha256OfFile(file.path);
  }

  PluginMarketStore buildStore({
    required String sha,
    Future<PluginIndex> Function()? loader,
    void Function(PluginIndexEntry entry)? onInstalled,
    void Function(String pluginId)? onUninstalled,
  }) {
    final installer = PluginInstaller(
      db: db,
      rootDir: pluginRoot,
      schemas: PluginSchemaRegistry(),
      fetch: fakeFetch,
    );
    return PluginMarketStore(
      installer: installer,
      indexLoader: loader ??
          () async => PluginIndex.parse(<String, Object?>{
                'schemaVersion': 1,
                'plugins': <Object?>[
                  <String, Object?>{
                    'id': 'demo_help',
                    'name': '使用说明',
                    'version': '1.0.0',
                    'contract': 1,
                    'description': '验证安装链路的示例插件',
                    'icon': 'help',
                    'permissions': <String>['task:read', 'task:write'],
                    'package': <String, Object?>{
                      'path': 'assets/plugins/demo_help_v1.0.0.zip',
                      'sha256': sha,
                      'sizeBytes': 1024,
                    },
                  },
                ],
              }),
      // urlFor 拿到的是 PluginPackage，版本号从包路径里抠出来
      urlFor: (pkg) {
        final match = RegExp(r'_v([\d.]+)\.zip$').firstMatch(pkg.path)!;
        return Uri.file(p.join(tempRoot.path, 'demo_help_v${match.group(1)}.zip'));
      },
      onInstalled: onInstalled,
      onUninstalled: onUninstalled,
    );
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('v6_market_');
    pluginRoot = Directory(p.join(tempRoot.path, 'plugins'));
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    shaValue = await buildZip();
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  /// 等真实的文件 IO 完成。
  ///
  /// `pump(Duration)` 推的是假时钟，不会让 `dart:io` 的 Future 落地，
  /// 所以安装/卸载这种"点击后真的读写磁盘"的路径必须用 runAsync 放真实时间。
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 200; i++) {
      if (done()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    fail('等待超时');
  }

  group('PluginMarketStore', () {
    test('首次刷新：可安装 1 个，已安装 0 个', () async {
      final store = buildStore(sha: shaValue);
      await store.refresh();

      expect(store.installed, isEmpty);
      expect(store.available, hasLength(1));
      expect(store.available.single.name, '使用说明');
    });

    test('安装后进已安装、离开可安装；卸载后还原', () async {
      final store = buildStore(sha: shaValue);
      await store.refresh();

      await store.install(store.available.single);

      expect(store.installed, hasLength(1));
      expect(store.installed.single.pluginId, 'demo_help');
      expect(store.available, isEmpty);
      expect(
        File(p.join(pluginRoot.path, 'demo_help', '1.0.0', 'index.html')).existsSync(),
        isTrue,
      );

      await store.uninstall('demo_help');
      expect(store.installed, isEmpty);
      expect(store.available, hasLength(1));
      expect(Directory(p.join(pluginRoot.path, 'demo_help')).existsSync(), isFalse);
    });

    test('安装失败会记下原因，且不留下已安装记录', () async {
      final store = buildStore(sha: 'c' * 64); // 与包内容不匹配
      await store.refresh();

      await expectLater(store.install(store.available.single), throwsA(anything));

      expect(store.lastError, isNotNull);
      expect(store.installed, isEmpty);
      expect(store.progressOf('demo_help'), isNull);
    });

    test('索引取不到时：报错但已安装列表仍然可用', () async {
      final store = buildStore(
        sha: shaValue,
        loader: () async => throw const FormatException('no network'),
      );
      await store.refresh();

      expect(store.indexError, isNotNull);
      expect(store.available, isEmpty);
      expect(store.installed, isEmpty);

      // 手动装一个已经存在的（索引没了也能操作已安装的部分）
      await store.install(
        PluginIndexEntry(
          id: 'demo_help',
          name: '使用说明',
          version: '1.0.0',
          contract: 1,
          package: PluginPackage(
            path: 'assets/plugins/demo_help_v1.0.0.zip',
            sha256: shaValue,
            sizeBytes: 1024,
          ),
        ),
      );
      expect(store.installed, hasLength(1));
    });

    test('装 1.0.0、索引升到 1.1.0：updateFor 给出新条目', () async {
      final sha110 = await buildZip(version: '1.1.0');
      final store = buildStore(
        sha: shaValue,
        loader: () async => _indexWithVersion('1.1.0', sha110),
      );

      // 先手动装 1.0.0（索引此时没有 1.0.0 条目，走与"索引没了也能操作"同一路径）
      await store.install(_entryWithVersion('1.0.0', shaValue));
      await store.refresh();

      expect(store.installed.single.version, '1.0.0');
      final update = store.updateFor(store.installed.single);
      expect(update, isNotNull);
      expect(update!.version, '1.1.0');
      // 有更新时不该出现在"可安装"里（那条货架位是升级按钮的）
      expect(store.available, isEmpty);
    });

    test('升级：版本号变 1.1.0，旧版本目录清掉，数据保留，不再触发 onInstalled', () async {
      final sha110 = await buildZip(version: '1.1.0');
      var installCalls = 0;
      final store = buildStore(
        sha: shaValue,
        loader: () async => _indexWithVersion('1.1.0', sha110),
        onInstalled: (_) => installCalls++,
      );

      await store.install(_entryWithVersion('1.0.0', shaValue));
      expect(installCalls, 1, reason: '首次安装触发 onInstalled');
      await store.refresh();

      final update = store.updateFor(store.installed.single)!;
      await store.install(update);

      expect(store.installed.single.version, '1.1.0');
      expect(installCalls, 1, reason: '升级不是首次安装，不能再报一次初始状态');
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help', '1.0.0')).existsSync(),
        isFalse,
        reason: '旧版本目录应被清掉',
      );
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help', '1.1.0')).existsSync(),
        isTrue,
      );
      expect(store.updateFor(store.installed.single), isNull, reason: '升完就没有更新了');
    });

    /// 装一个**声明了私有表**的 1.2.0，并在表里放一行数据
    Future<PluginMarketStore> installWithData({void Function(String id)? onUninstalled}) async {
      final shaStorage = await buildZip(version: '1.2.0', withStorage: true);
      final store = buildStore(
        sha: shaStorage,
        loader: () async => _indexWithVersion('1.2.0', shaStorage),
        onUninstalled: onUninstalled,
      );
      await store.refresh();
      await store.install(store.available.single);
      await db.insert('plg_demo_help_entries', <String, Object?>{
        'day': '2026-10-28',
        'minutes': 25,
      });
      return store;
    }

    test('卸载默认保留数据：表和数据都还在，装回来能读到', () async {
      final store = await installWithData();

      await store.uninstall('demo_help');

      expect(store.installed, isEmpty, reason: '代码和登记都清了');
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help')).existsSync(),
        isFalse,
        reason: '插件目录要删掉',
      );
      final kept = await db.query('plg_demo_help_entries');
      expect(kept, hasLength(1), reason: '默认保留 = 插件表不能 DROP');

      // 装回来：数据还在（建表是 IF NOT EXISTS，不会把表清空）
      await store.install(store.available.single);
      final back = await db.query('plg_demo_help_entries');
      expect(back.single['minutes'], 25);
    });

    test('卸载时勾了删数据：插件表、KV、余额镜像一起没', () async {
      final store = await installWithData();
      final settings = SettingsRepository(db);
      await settings.set('plg.demo_help.balance', '10');
      await settings.setInt(SettingsKeys.currencyBalance('demo_help'), 10);
      await settings.set(SettingsKeys.activeCurrency, 'demo_help');
      await settings.setInt(SettingsKeys.homeFailures('demo_help'), 2);
      // 另一个插件的前缀相近，必须不能被误删（`_` 在 LIKE 里是通配符）
      await settings.set('plg.demoXhelp.balance', '99');

      await store.uninstall('demo_help', keepData: false);

      await expectLater(db.query('plg_demo_help_entries'), throwsA(anything));
      expect(await settings.get('plg.demo_help.balance'), isNull);
      expect(await settings.get(SettingsKeys.currencyBalance('demo_help')), isNull);
      expect(await settings.get(SettingsKeys.activeCurrency), isNull);
      expect(await settings.get(SettingsKeys.homeFailures('demo_help')), isNull);
      expect(
        await settings.get('plg.demoXhelp.balance'),
        '99',
        reason: '前缀相近的另一个插件不能连坐',
      );
    });

    test('卸载会通知应用层（首页/货币要跟着失效）', () async {
      String? notified;
      final store = await installWithData(onUninstalled: (id) => notified = id);

      await store.uninstall('demo_help');

      expect(notified, 'demo_help');
    });
  });

  group('PluginMarketPage', () {
    testWidgets('空货架显示两个空状态', (tester) async {
      final store = buildStore(sha: shaValue);
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      expect(find.text('还没有安装插件'), findsOneWidget);
      expect(find.text('可安装 · 1'), findsOneWidget);
      expect(find.text('使用说明'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
    });

    testWidgets('点安装先弹权限告知；取消就什么都不装', (tester) async {
      final store = buildStore(sha: shaValue);
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      await tester.tap(find.text('安装'));
      await tester.pumpAndSettle();

      expect(find.text('安装「使用说明」？'), findsOneWidget);
      expect(find.text('读取你的任务（标题、日期、优先级、标签）'), findsOneWidget);
      expect(find.text('新建和修改你的任务'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(store.installed, isEmpty, reason: '取消了就不该装');
      expect(find.text('可安装 · 1'), findsOneWidget);
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help')).existsSync(),
        isFalse,
        reason: '连下载都不该发生',
      );
    });

    testWidgets('点安装：进入已安装，文件真的落盘', (tester) async {
      final store = buildStore(sha: shaValue);
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      await tester.tap(find.text('安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '安装'));
      await waitFor(tester, () => store.installed.isNotEmpty);
      await settle(tester);

      expect(find.text('已安装 · 1'), findsOneWidget);
      expect(find.text('暂无可用插件'), findsOneWidget);
      expect(find.text('卸载'), findsOneWidget);
      expect(
        File(p.join(pluginRoot.path, 'demo_help', '1.0.0', 'index.html')).existsSync(),
        isTrue,
      );
    });

    testWidgets('点卸载并确认：回到空状态，目录消失', (tester) async {
      final store = buildStore(sha: shaValue);
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      await tester.tap(find.text('安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '安装'));
      await waitFor(tester, () => store.installed.isNotEmpty);
      await settle(tester);

      await tester.tap(find.text('卸载'));
      await tester.pumpAndSettle();
      expect(find.text('卸载「使用说明」？'), findsOneWidget, reason: '卸载要先确认');

      await tester.tap(find.widgetWithText(TextButton, '卸载'));
      await waitFor(tester, () => store.installed.isEmpty);
      await settle(tester);

      expect(find.text('已安装 · 0'), findsOneWidget);
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help')).existsSync(),
        isFalse,
      );
    });

    testWidgets('卸载弹窗默认不删数据；勾上「同时删除」才清表', (tester) async {
      final shaStorage = (await tester.runAsync(
        () => buildZip(version: '1.2.0', withStorage: true),
      ))!;
      final store = buildStore(
        sha: shaStorage,
        loader: () async => _indexWithVersion('1.2.0', shaStorage),
      );
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      await tester.tap(find.text('安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '安装'));
      await waitFor(tester, () => store.installed.isNotEmpty);
      await settle(tester);
      await tester.runAsync(
        () => db.insert('plg_demo_help_entries', <String, Object?>{
          'day': '2026-10-28',
          'minutes': 25,
        }),
      );

      // 第一次：不勾，数据留着
      await tester.tap(find.text('卸载'));
      await tester.pumpAndSettle();
      expect(find.text('同时删除它的数据'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse,
          reason: '破坏性选项默认不勾');
      await tester.tap(find.widgetWithText(TextButton, '卸载'));
      await waitFor(tester, () => store.installed.isEmpty);
      await settle(tester);
      expect(find.text('已卸载，数据保留'), findsOneWidget);
      expect(
        (await tester.runAsync(() => db.query('plg_demo_help_entries')))!,
        hasLength(1),
      );

      // 第二次：勾上，表清空
      await tester.tap(find.text('安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '安装'));
      await waitFor(tester, () => store.installed.isNotEmpty);
      await settle(tester);

      await tester.tap(find.text('卸载'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '卸载'));
      await waitFor(tester, () => store.installed.isEmpty);
      await settle(tester);

      expect(find.text('已卸载，数据已删除'), findsOneWidget);
      // 表已被 DROP。查 sqlite_master 而不是直接 query 表 ——
      // `runAsync` 会把异常吞成本 test 之外的错误，断言不到。
      final tables = await tester.runAsync(
        () => db.query(
          'sqlite_master',
          where: 'name = ?',
          whereArgs: <Object?>['plg_demo_help_entries'],
        ),
      );
      expect(tables, isEmpty, reason: '勾了删数据，插件表要被 DROP');
    });

    testWidgets('有新版本时：显示升级按钮；确认后版本落盘、升级按钮消失', (tester) async {
      // 造包、安装、刷新**全都得包 runAsync**：`testWidgets` 跑在假时钟里，
      // 真实文件 IO 的 Future 不会被推进，直接 await 会一直挂到用例超时
      // （报错只有一句 "did not complete"，看不出是哪一行）。
      final sha110 = (await tester.runAsync(() => buildZip(version: '1.1.0')))!;
      final store = buildStore(
        sha: shaValue,
        loader: () async => _indexWithVersion('1.1.0', sha110),
      );
      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      // 先装 1.0.0（手动条目，绕过"索引里没有 1.0.0"）
      await tester.runAsync(() => store.install(_entryWithVersion('1.0.0', shaValue)));
      await tester.runAsync(store.refresh);
      await settle(tester);

      expect(find.text('升级'), findsOneWidget, reason: '已安装区出现升级按钮');
      expect(find.text('v1.0.0 → v1.1.0'), findsOneWidget);

      await tester.tap(find.text('升级'));
      await tester.pumpAndSettle();
      expect(find.text('升级「使用说明」？'), findsOneWidget);
      expect(find.text('升级会保留这个插件已有的数据。'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '升级').last);
      await waitFor(tester, () => store.installed.single.version == '1.1.0');
      await settle(tester);

      expect(find.text('升级'), findsNothing, reason: '升完就没有更新了');
      expect(
        File(p.join(pluginRoot.path, 'demo_help', '1.1.0', 'index.html')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help', '1.0.0')).existsSync(),
        isFalse,
      );
    });
  });
}
