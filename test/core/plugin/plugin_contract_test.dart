// 插件契约的解析与校验测试。
//
// 重点不是"能读 JSON"，而是**能不能挡住坏包**：
//   - id 会进目录名和 `plg_<id>_` 表前缀
//   - entry 会拼进 WebView 的本地 URL
// 这两处一旦让 `..` 或绝对路径通过，后果是越界读写，不是"显示难看"。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
import 'package:v5_app/core/plugin/plugin_store.dart';

Map<String, Object?> _manifestJson({
  String id = 'pomodoro',
  String version = '1.0.0',
  int contract = 1,
  String entry = 'index.html',
  Object? slots,
}) =>
    <String, Object?>{
      'id': id,
      'name': '番茄钟',
      'version': version,
      'contract': contract,
      'entry': entry,
      'description': '专注计时',
      'icon': 'timer',
      'slots': ?slots,
    };

final String _sha = 'a' * 64;

Map<String, Object?> _indexJson({List<Object?>? plugins, int schema = 1}) => <String, Object?>{
      'schemaVersion': schema,
      'plugins': plugins ??
          <Object?>[
            <String, Object?>{
              'id': 'pomodoro',
              'name': '番茄钟',
              'version': '1.0.0',
              'contract': 1,
              'package': <String, Object?>{
                'path': 'plugins/pomodoro_v1.0.0.zip',
                'sha256': _sha,
                'sizeBytes': 4096,
              },
            },
          ],
    };

void main() {
  group('PluginManifest', () {
    test('合法清单能解析，插槽按 id 映射', () {
      final m = PluginManifest.parse(_manifestJson(
        slots: <Object?>['slot.taskCardExtra', 'slot.headerDate'],
      ));

      expect(m.id, 'pomodoro');
      expect(m.name, '番茄钟');
      expect(m.contract, 1);
      expect(m.entry, 'index.html');
      expect(m.slots, <SlotId>{SlotId.taskCardExtra, SlotId.headerDate});
    });

    test('不认识的插槽被忽略，不导致整个插件装不上', () {
      final m = PluginManifest.parse(_manifestJson(
        slots: <Object?>['slot.taskCardExtra', 'slot.未来才有的插槽'],
      ));
      expect(m.slots, <SlotId>{SlotId.taskCardExtra});
    });

    test('id 非法：大写 / 带横线 / 太短 / 太长', () {
      for (final bad in <String>['Pomodoro', 'pomo-doro', 'a', 'a' * 33, '']) {
        expect(
          () => PluginManifest.parse(_manifestJson(id: bad)),
          throwsA(isA<PluginFormatException>()),
          reason: '应该拒绝 id=$bad',
        );
      }
    });

    test('version 必须是 x.y.z', () {
      for (final bad in <String>['1.0', 'v1.0.0', '1.0.0-beta', '']) {
        expect(
          () => PluginManifest.parse(_manifestJson(version: bad)),
          throwsA(isA<PluginFormatException>()),
          reason: '应该拒绝 version=$bad',
        );
      }
    });

    test('契约版本超出宿主范围要拒绝', () {
      expect(
        () => PluginManifest.parse(_manifestJson(contract: 99)),
        throwsA(isA<PluginFormatException>()),
      );
      expect(
        () => PluginManifest.parse(_manifestJson(contract: 0)),
        throwsA(isA<PluginFormatException>()),
      );
    });

    test('entry 不能跳出包目录', () {
      for (final bad in <String>['../evil.html', '/abs.html', 'a\\b.html', '', 'index.js', 'a//b.html']) {
        expect(
          () => PluginManifest.parse(_manifestJson(entry: bad)),
          throwsA(isA<PluginFormatException>()),
          reason: '应该拒绝 entry=$bad',
        );
      }
      // 子目录里的入口是允许的
      expect(PluginManifest.parse(_manifestJson(entry: 'pages/index.html')).entry,
          'pages/index.html');
    });
  });

  group('PluginPackage', () {
    Map<String, Object?> pkg({String path = 'plugins/a.zip', String? sha, Object? size = 100}) =>
        <String, Object?>{'path': path, 'sha256': sha ?? _sha, 'sizeBytes': size};

    test('合法包描述', () {
      final p = PluginPackage.fromJson(pkg());
      expect(p.path, 'plugins/a.zip');
      expect(p.sha256.length, 64);
    });

    test('路径穿越 / 绝对路径 / 反斜杠都要拒绝', () {
      for (final bad in <String>['../a.zip', '/etc/a.zip', 'plugins\\a.zip']) {
        expect(() => PluginPackage.fromJson(pkg(path: bad)),
            throwsA(isA<PluginFormatException>()), reason: '应该拒绝 path=$bad');
      }
    });

    test('sha256 必须是 64 位小写十六进制', () {
      for (final bad in <String>['abc', 'A' * 64, 'g' * 64]) {
        expect(() => PluginPackage.fromJson(pkg(sha: bad)),
            throwsA(isA<PluginFormatException>()), reason: '应该拒绝 sha=$bad');
      }
    });

    test('sizeBytes 必须是正整数', () {
      expect(() => PluginPackage.fromJson(pkg(size: 0)),
          throwsA(isA<PluginFormatException>()));
      expect(() => PluginPackage.fromJson(pkg(size: null)),
          throwsA(isA<PluginFormatException>()));
    });
  });

  group('PluginIndex', () {
    test('合法索引能解析', () {
      final index = PluginIndex.parse(_indexJson());
      expect(index.plugins, hasLength(1));
      expect(index.findById('pomodoro')?.version, '1.0.0');
      expect(index.findById('nope'), isNull);
    });

    test('schemaVersion 不匹配要拒绝', () {
      expect(() => PluginIndex.parse(_indexJson(schema: 2)),
          throwsA(isA<PluginFormatException>()));
    });

    test('重复 id 要拒绝（否则"装的是哪个"不确定）', () {
      final item = <String, Object?>{
        'id': 'pomodoro',
        'name': '番茄钟',
        'version': '1.0.0',
        'contract': 1,
        'package': <String, Object?>{'path': 'a.zip', 'sha256': _sha, 'sizeBytes': 1},
      };
      expect(
        () => PluginIndex.parse(_indexJson(plugins: <Object?>[item, item])),
        throwsA(isA<PluginFormatException>()),
      );
    });

    test('空索引可解析（首版空货架用它）', () {
      expect(PluginIndex.empty.plugins, isEmpty);
    });

    test('installable 反映契约兼容性', () {
      final index = PluginIndex.parse(_indexJson(plugins: <Object?>[
        <String, Object?>{
          'id': 'old',
          'name': '老插件',
          'version': '1.0.0',
          'contract': 99,
          'package': <String, Object?>{'path': 'a.zip', 'sha256': _sha, 'sizeBytes': 1},
        },
      ]));
      expect(index.plugins.single.installable, isFalse);
    });
  });

  group('PluginStore', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    Future<(Database, PluginStore)> open() async {
      final db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      return (db, PluginStore(db));
    }

    test('已安装插件表在打开库时就存在（老库也会补建）', () async {
      final (db, _) = await open();
      addTearDown(db.close);
      final tables = await V6Database.listTables(db);
      expect(tables, contains('installed_plugins'));
    });

    test('写入 / 读取 / 删除', () async {
      final (db, store) = await open();
      addTearDown(db.close);

      await store.upsert(InstalledPlugin(
        pluginId: 'pomodoro',
        version: '1.0.0',
        contract: 1,
        installDir: 'pomodoro/1.0.0',
        installedAt: DateTime.utc(2026, 10, 22),
      ));

      final found = await store.find('pomodoro');
      expect(found, isNotNull);
      expect(found!.version, '1.0.0');
      expect(found.installDir, 'pomodoro/1.0.0');
      expect(found.enabled, isTrue);

      await store.setEnabled('pomodoro', false);
      expect((await store.find('pomodoro'))!.enabled, isFalse);

      // 同 id 再写一次是覆盖，不是新增
      await store.upsert(InstalledPlugin(
        pluginId: 'pomodoro',
        version: '1.1.0',
        contract: 1,
        installDir: 'pomodoro/1.1.0',
        installedAt: DateTime.utc(2026, 10, 23),
      ));
      expect(await store.all(), hasLength(1));
      expect((await store.find('pomodoro'))!.version, '1.1.0');

      await store.remove('pomodoro');
      expect(await store.find('pomodoro'), isNull);
    });
  });
}
