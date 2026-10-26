// 首页模式的熔断测试。
//
// 可换首页最怕的不是"加载慢"，是"加载失败后没有界面可以操作"。
// 所以这里的断言全围绕一件事：**失败几次之后，应用必须自己回到内置首页**，
// 而且这个判断要在渲染之前就能做出来。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/state/home_mode_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/home/home_mode.dart';

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
    addTearDown(db.close);
    settings = SettingsRepository(db);
  });

  group('HomeMode 解析', () {
    test('空值 / 认不出来的值都回到内置', () {
      expect(HomeMode.parse(null).isBuiltin, isTrue);
      expect(HomeMode.parse('').isBuiltin, isTrue);
      expect(HomeMode.parse('builtin').isBuiltin, isTrue);
      expect(HomeMode.parse('plugin:').isBuiltin, isTrue);
      expect(HomeMode.parse('乱七八糟').isBuiltin, isTrue);
    });

    test('编码再解析能还原', () {
      const mode = HomeMode.plugin('demo_help');
      expect(HomeMode.parse(mode.encode()), mode);
      expect(mode.encode(), 'plugin:demo_help');
    });
  });

  group('启动时的失败计数', () {
    test('上次正常渲染过：不记失败', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '1');

      final store = HomeModeStore(settings);
      await store.load();

      expect(store.mode.pluginId, 'demo');
      expect(store.failures, 0);
      expect(store.autoDowngraded, isFalse);
    });

    test('上次没渲染完（进程被杀/崩了）：记一次失败，但不马上降级', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '0');

      final store = HomeModeStore(settings);
      await store.load();

      expect(store.failures, 1);
      expect(store.mode.pluginId, 'demo', reason: '一次失败不至于换掉首页');
      expect(store.autoDowngraded, isFalse);
    });

    test('连续两次没渲染完：自动切回内置，并落库', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '0');

      final first = HomeModeStore(settings);
      await first.load();
      expect(first.failures, 1);

      // 模拟"这一次又崩了"：会话标记仍然是 0
      final second = HomeModeStore(settings);
      await second.load();

      expect(second.failures, 2);
      expect(second.mode.isBuiltin, isTrue);
      expect(second.autoDowngraded, isTrue);
      expect(await settings.get(SettingsKeys.homeMode), 'builtin');

      // 下次启动不要再试着加载那个插件
      final third = HomeModeStore(settings);
      await third.load();
      expect(third.mode.isBuiltin, isTrue);
    });

    test('渲染成功一次就把计数清零', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '0');

      final store = HomeModeStore(settings);
      await store.load();
      expect(store.failures, 1);

      await store.markRendered();

      expect(store.failures, 0);
      expect(await settings.get(SettingsKeys.sessionClean), '1');
    });
  });

  group('运行中失败', () {
    test('达到上限才降级，且返回"已降级"', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '1');

      final store = HomeModeStore(settings);
      await store.load();

      expect(await store.reportFailure(), isFalse);
      expect(store.mode.pluginId, 'demo');

      expect(await store.reportFailure(), isTrue);
      expect(store.mode.isBuiltin, isTrue);
      expect(await settings.get(SettingsKeys.homeMode), 'builtin');
    });

    test('内置首页上报失败不会把计数搅乱', () async {
      final store = HomeModeStore(settings);
      await store.load();

      expect(await store.reportFailure(), isFalse);
      expect(store.failures, 0);
    });
  });

  group('切换', () {
    test('用户手动切回插件首页时清掉历史失败，不会一上来就被踢走', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '0');
      final store = HomeModeStore(settings);
      await store.load();
      expect(store.failures, 1);

      await store.setMode(const HomeMode.plugin('demo'));

      expect(store.failures, 0);
      expect(store.mode.pluginId, 'demo');
    });

    test('当选首页的插件被卸载：直接回内置', () async {
      await settings.set(SettingsKeys.homeMode, 'plugin:demo');
      await settings.set(SettingsKeys.sessionClean, '1');
      final store = HomeModeStore(settings);
      await store.load();

      await store.onPluginUninstalled('other');
      expect(store.mode.pluginId, 'demo', reason: '卸的不是它，不该动');

      await store.onPluginUninstalled('demo');
      expect(store.mode.isBuiltin, isTrue);
    });
  });
}
