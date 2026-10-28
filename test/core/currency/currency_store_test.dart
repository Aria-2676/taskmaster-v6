// 货币状态层：谁是当前货币、余额镜像怎么维护。
//
// 这里最值得盯的是两条：
//   1. "第一个报告余额的插件成为当前货币" —— 决定了用户装完能不能马上看到数字
//   2. 非当前货币的写入仍要存下来 —— 否则以后切换货币会看到一个陈旧值

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/state/currency_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late SettingsRepository settings;
  late CurrencyStore store;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    settings = SettingsRepository(db);
    store = CurrencyStore(settings);
  });

  test('全新安装：没有货币，徽章不显示', () async {
    await store.load();

    expect(store.installed, isFalse);
    expect(store.balance, 0);
    expect(
      store.provide(SlotId.currencyBadge, const <String, Object?>{}),
      isNull,
      reason: '没有货币时插槽要交回 null，主包才好落到"不画徽章"',
    );
  });

  test('第一个报告余额的插件成为当前货币', () async {
    await store.load();
    await store.report('energy_currency', 120);

    expect(store.providerId, 'energy_currency');
    expect(store.balance, 120);
    expect(await settings.get(SettingsKeys.activeCurrency), 'energy_currency');

    final value = store.provide(SlotId.currencyBadge, const <String, Object?>{});
    expect(value, isA<CurrencyBadgeValue>());
    expect((value! as CurrencyBadgeValue).value, 120);
  });

  test('第二个插件报告余额：存下来，但不抢显示位', () async {
    await store.load();
    await store.report('energy_currency', 120);
    await store.report('coins', 999);

    expect(store.providerId, 'energy_currency', reason: '先来的占着显示位');
    expect(store.balance, 120, reason: '顶栏还是能量的数字');
    expect(await store.balanceOf('coins'), 999, reason: '但金币的值要记住');
  });

  test('用户切换货币：余额立刻换成新的那个', () async {
    await store.load();
    await store.report('energy_currency', 120);
    await store.report('coins', 999);

    await store.select('coins');
    expect(store.providerId, 'coins');
    expect(store.balance, 999);
  });

  test('关掉货币：徽章消失，但各插件的余额还留着', () async {
    await store.load();
    await store.report('energy_currency', 120);

    await store.select(null);
    expect(store.installed, isFalse);
    expect(store.provide(SlotId.currencyBadge, const <String, Object?>{}), isNull);
    expect(await store.balanceOf('energy_currency'), 120);
  });

  test('卸载提供货币的插件：当前货币失效', () async {
    await store.load();
    await store.report('energy_currency', 120);

    await store.onPluginUninstalled('energy_currency');
    expect(store.installed, isFalse);
    expect(store.balance, 0);
    expect(await settings.get(SettingsKeys.activeCurrency), '');
  });

  test('卸载别的插件不影响当前货币', () async {
    await store.load();
    await store.report('energy_currency', 120);

    await store.onPluginUninstalled('demo_help');
    expect(store.providerId, 'energy_currency');
  });

  test('重启后余额还在（落库了，不是内存）', () async {
    await store.load();
    await store.report('energy_currency', 45);

    final fresh = CurrencyStore(settings);
    await fresh.load();
    expect(fresh.providerId, 'energy_currency');
    expect(fresh.balance, 45);
  });
}
