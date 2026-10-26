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
import 'package:v5_app/app/pages/plugin_market_page.dart';
import 'package:v5_app/app/state/plugin_market_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_installer.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
import 'package:v5_app/core/services/file_downloader.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tempRoot;
  late Directory pluginRoot;
  late Database db;
  late String zipPath;
  late String shaValue;

  Future<void> fakeFetch({
    required Uri url,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) async {
    await File(url.toFilePath()).copy(destPath);
    onProgress?.call(1, 1);
  }

  /// 造一个与 assets 里那个示例插件同构的 zip
  Future<String> buildZip() async {
    final archive = Archive();
    final manifest = utf8.encode(jsonEncode(<String, Object?>{
      'id': 'demo_help',
      'name': '使用说明',
      'version': '1.0.0',
      'contract': 1,
      'entry': 'index.html',
      'icon': 'help',
    }));
    final html = utf8.encode('<html><body>hi</body></html>');
    archive.addFile(ArchiveFile('plugin.json', manifest.length, manifest));
    archive.addFile(ArchiveFile('index.html', html.length, html));
    final file = File(p.join(tempRoot.path, 'demo_help.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return await FileDownloader.sha256OfFile(file.path);
  }

  PluginMarketStore buildStore({
    required String sha,
    Future<PluginIndex> Function()? loader,
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
      urlFor: (_) => Uri.file(zipPath),
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
    zipPath = p.join(tempRoot.path, 'demo_help.zip');
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
      expect(find.text('卸载插件'), findsOneWidget, reason: '卸载要先确认');

      await tester.tap(find.widgetWithText(TextButton, '卸载'));
      await waitFor(tester, () => store.installed.isEmpty);
      await settle(tester);

      expect(find.text('已安装 · 0'), findsOneWidget);
      expect(
        Directory(p.join(pluginRoot.path, 'demo_help')).existsSync(),
        isFalse,
      );
    });
  });
}
