// 插件索引的加载策略：远端 → 本地缓存 → 随包兜底。
//
// 这一层决定了"发了新插件用户能不能看到"，也是"断网还能不能装"的全部逻辑，
// 所以三条降级路径都要有用例，而不是只测顺利的那条。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_index_loader.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/pages/plugin_market_page.dart';
import 'package:v5_app/app/state/plugin_market_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_installer.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late SettingsRepository settings;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  /// 本文件不测下载链路，但 store 的构造非要一个安装器。
  /// fetch 一旦被调用就记一笔 —— 「超限的包不该开始下载」那条断言靠它。
  PluginInstaller installerFor({void Function()? onFetch}) => PluginInstaller(
        db: db,
        rootDir: Directory.systemTemp,
        schemas: PluginSchemaRegistry(),
        fetch: ({
          required Uri url,
          required String destPath,
          void Function(int received, int? total)? onProgress,
        }) async {
          onFetch?.call();
          throw Exception('这个用例不该真的下载');
        },
      );

  String indexJson({String id = 'demo_help', String version = '1.0.0'}) =>
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'plugins': <Object?>[
          <String, Object?>{
            'id': id,
            'name': '使用说明',
            'version': version,
            'contract': 1,
            'permissions': <String>['task:read'],
            'package': <String, Object?>{
              'path': 'assets/plugins/${id}_v$version.zip',
              'sha256': 'a' * 64,
              'sizeBytes': 1024,
            },
          },
        ],
      });

  group('三级降级', () {
    test('远端拿得到：来源 remote，并把原文写进缓存', () async {
      final loader = PluginIndexLoader(
        fetchRemote: () async => indexJson(version: '2.0.0'),
        loadBundled: () async => fail('不该退到随包那份'),
        settings: settings,
      );

      final result = await loader.load();

      expect(result.source, PluginIndexSource.remote);
      expect(result.index.plugins.single.version, '2.0.0');
      expect(result.fetchedAt, isNotNull);
      // 缓存是为了"下次断网还能用"，所以这一刻必须已经写进去
      expect(await settings.get(SettingsKeys.pluginIndexJson), isNotNull);
      expect(await settings.get(SettingsKeys.pluginIndexFetchedAt), isNotNull);
    });

    test('远端挂了 + 有缓存：来源 cache，时间来自缓存，错误原文留着', () async {
      await settings.set(SettingsKeys.pluginIndexJson, indexJson(version: '1.5.0'));
      await settings.set(
        SettingsKeys.pluginIndexFetchedAt,
        DateTime.utc(2026, 10, 28, 5, 40).toIso8601String(),
      );

      final loader = PluginIndexLoader(
        fetchRemote: () async => throw Exception('HTTP 502'),
        loadBundled: () async => fail('有缓存就不该退到随包'),
        settings: settings,
      );

      final result = await loader.load();

      expect(result.source, PluginIndexSource.cache);
      expect(result.index.plugins.single.version, '1.5.0');
      expect(result.fetchedAt, DateTime.utc(2026, 10, 28, 5, 40));
      expect(result.remoteError, contains('HTTP 502'));
    });

    test('远端挂了 + 缓存坏了：继续退到随包那份', () async {
      await settings.set(SettingsKeys.pluginIndexJson, '{ 这不是 JSON');

      final loader = PluginIndexLoader(
        fetchRemote: () async => throw Exception('timeout'),
        loadBundled: () async => indexJson(version: '1.0.0'),
        settings: settings,
      );

      final result = await loader.load();

      expect(result.source, PluginIndexSource.bundled);
      expect(result.index.plugins.single.version, '1.0.0');
      expect(result.remoteError, contains('timeout'));
    });

    test('有新版索引时缓存会被覆盖（不然用户永远看到旧的）', () async {
      var counter = 0;
      final loader = PluginIndexLoader(
        fetchRemote: () async => indexJson(version: counter++ == 0 ? '1.0.0' : '1.1.0'),
        loadBundled: () async => indexJson(),
        settings: settings,
      );

      expect((await loader.load()).index.plugins.single.version, '1.0.0');
      expect((await loader.load()).index.plugins.single.version, '1.1.0');

      final cached = await settings.get(SettingsKeys.pluginIndexJson);
      expect(cached, contains('1.1.0'));
    });
  });

  group('体积上限', () {
    test('包超过 20MB：下载之前就拒绝，给一句人话', () async {
      var fetchCalled = false;
      final loader = PluginIndexLoader(
        fetchRemote: () async => jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'plugins': <Object?>[
            <String, Object?>{
              'id': 'huge',
              'name': '大插件',
              'version': '1.0.0',
              'contract': 1,
              'permissions': <String>[],
              'package': <String, Object?>{
                'path': 'assets/plugins/huge_v1.0.0.zip',
                'sha256': 'b' * 64,
                'sizeBytes': PluginMarketStore.maxPackageBytes + 1,
              },
            },
          ],
        }),
        loadBundled: () async => indexJson(),
        settings: settings,
      );
      final index = (await loader.load()).index;

      final store = PluginMarketStore(
        installer: installerFor(onFetch: () => fetchCalled = true),
        indexLoader: () async => PluginIndexResult.bundled(index),
        urlFor: (pkg) => Uri.file(pkg.path),
      );
      await store.refresh();

      await expectLater(
        store.install(index.plugins.single),
        throwsA(isA<Object>()),
      );
      expect(fetchCalled, isFalse, reason: '超限的包不该开始下载');
      expect(store.lastError, contains('20MB'));
    });
  });

  group('多镜像取最新', () {
    PluginIndex parseOf(String text) =>
        PluginIndex.parse(Map<String, Object?>.from(jsonDecode(text) as Map));

    String idxWith(DateTime? at, String version) => jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          if (at != null) 'publishedAt': at.toIso8601String(),
          'plugins': <Object?>[
            <String, Object?>{
              'id': 'demo_help',
              'name': '使用说明',
              'version': version,
              'contract': 1,
              'permissions': <String>[],
              'package': <String, Object?>{
                'path': 'plugins/packages/demo_help_v$version.zip',
                'sha256': 'c' * 64,
                'sizeBytes': 1,
              },
            },
          ],
        });

    test('旧节点先返回也不影响：取 publishedAt 最新的那份', () async {
      final oldText = idxWith(DateTime.utc(2026, 10, 28, 9), '1.0.0');
      final newText = idxWith(DateTime.utc(2026, 10, 28, 10), '2.0.0');

      final text = await PluginIndexLoader.fetchNewestIndex(
        <Uri>[Uri.parse('https://stale.example/i.json'), Uri.parse('https://fresh.example/i.json')],
        grace: const Duration(milliseconds: 80),
        fetch: (uri, {required bool viaContentsApi, required Duration timeout}) async {
          // 旧节点"更快" —— 这正是线上 gcore 的样子
          if (uri.host == 'stale.example') return oldText;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return newText;
        },
      );

      expect(parseOf(text).plugins.single.version, '2.0.0');
      expect(parseOf(text).publishedAt, DateTime.utc(2026, 10, 28, 10));
    });

    test('老索引没有 publishedAt：按最旧处理，输给带时间戳的', () async {
      final legacy = idxWith(null, '1.0.0');
      final fresh = idxWith(DateTime.utc(2026, 10, 28, 10), '1.1.0');

      final text = await PluginIndexLoader.fetchNewestIndex(
        <Uri>[Uri.parse('https://a.example/i.json'), Uri.parse('https://b.example/i.json')],
        grace: const Duration(milliseconds: 80),
        fetch: (uri, {required bool viaContentsApi, required Duration timeout}) async =>
            uri.host == 'a.example' ? legacy : fresh,
      );

      expect(parseOf(text).plugins.single.version, '1.1.0');
    });

    test('一个源挂了不影响：用活着的那份', () async {
      final fresh = idxWith(DateTime.utc(2026, 10, 28, 10), '1.1.0');
      final text = await PluginIndexLoader.fetchNewestIndex(
        <Uri>[Uri.parse('https://dead.example/i.json'), Uri.parse('https://ok.example/i.json')],
        grace: const Duration(milliseconds: 50),
        fetch: (uri, {required bool viaContentsApi, required Duration timeout}) async {
          if (uri.host == 'dead.example') throw Exception('HTTP 503');
          return fresh;
        },
      );
      expect(parseOf(text).plugins.single.version, '1.1.0');
    });

    test('全部失败：抛出来，让上层退到缓存', () async {
      await expectLater(
        PluginIndexLoader.fetchNewestIndex(
          <Uri>[Uri.parse('https://a.example/i.json')],
          grace: const Duration(milliseconds: 20),
          fetch: (uri, {required bool viaContentsApi, required Duration timeout}) async =>
              throw Exception('offline'),
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('重试', () {
    test('刷新期间连点只拉一次（不然每点一次都是一轮多源超时）', () async {
      var calls = 0;
      var block = false;
      final gate = Completer<String>();
      final loader = PluginIndexLoader(
        fetchRemote: () {
          calls++;
          if (block) return gate.future;
          throw Exception('offline');
        },
        loadBundled: () async => indexJson(),
        settings: settings,
      );
      final store = PluginMarketStore(
        installer: installerFor(),
        indexLoader: loader.load,
        urlFor: (pkg) => Uri.file(pkg.path),
      );
      await store.refresh();
      expect(store.indexRefreshing, isFalse);

      block = true;
      final first = store.refreshIndex();
      expect(store.indexRefreshing, isTrue, reason: '第一下要立刻进刷新态');
      // 用户以为没点上，再点两下
      unawaited(store.refreshIndex());
      unawaited(store.refreshIndex());
      expect(calls, 2, reason: '首次 refresh 1 次 + 这次 1 次，连点不该再加');

      gate.complete(indexJson(version: '9.9.9'));
      await first;
      expect(store.indexRefreshing, isFalse);
      expect(store.indexSource, PluginIndexSource.remote);
    });
  });

  group('状态行', () {
    /// 假时钟推不动 sqflite 的读库，必须给真实时间
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
    }

    testWidgets('降级到缓存时，页面显示索引时间 + 重试', (tester) async {
      final loader = PluginIndexLoader(
        fetchRemote: () async => throw Exception('offline'),
        loadBundled: () async => indexJson(),
        settings: settings,
      );
      // 先灌一份缓存，模拟"上次联网成功过"
      await settings.set(SettingsKeys.pluginIndexJson, indexJson(version: '1.4.0'));
      await settings.set(
        SettingsKeys.pluginIndexFetchedAt,
        DateTime.utc(2026, 10, 28, 5, 40).toIso8601String(),
      );

      final store = PluginMarketStore(
        installer: installerFor(),
        indexLoader: loader.load,
        urlFor: (pkg) => Uri.file(pkg.path),
      );

      await tester.pumpWidget(MaterialApp(home: PluginMarketPage(store: store)));
      await settle(tester);

      expect(find.textContaining('离线 · 显示'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // 点重试但网络还是不通：必须说一句，不能"点了没反应"
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.textContaining('还是连不上'), findsOneWidget);
    });
  });
}
