import 'package:sqflite/sqflite.dart';

import '../../core/data/v6_schema.dart';

/// 设置项的 key。**只放主包自己的开关**；插件的配置归插件自己的表。
class SettingsKeys {
  const SettingsKeys._();

  /// 删除前是否弹确认框（默认开）
  static const String confirmBeforeDelete = 'ui.confirm_before_delete';

  /// 删除后是否先进回收站（**默认关**：默认直接删掉，不留垃圾）
  static const String recycleBinEnabled = 'ui.recycle_bin_enabled';

  /// 回收站保留天数（默认 7）。到期由启动时的清理任务物理删除
  static const String recycleRetentionDays = 'ui.recycle_retention_days';

  /// 回收站保留天数的默认值
  static const int defaultRetentionDays = 7;

  /// 编辑页形态：`sheet`（底部弹层，默认）或 `full`（全屏）
  static const String editorForm = 'ui.editor_form';

  /// 字段偏好（顺序 / 关闭的字段 / 默认值覆盖），JSON 字符串
  static const String fieldPrefs = 'ui.field_prefs';

  /// 首页形态：`builtin` 或 `plugin:<id>`
  static const String homeMode = 'ui.home_mode';

  /// 顶栏「快捷切换」里**用户改过的**显示状态，逗号分隔，前缀 `+` 显示 / `-` 收起。
  ///
  /// 只记**偏离默认**的项：默认值由插件在 manifest 的 `home` 里声明
  /// （声明了 = 默认显示，没声明 = 默认收起）。这样插件升级后改了默认值，
  /// 没动过手的人会跟着新默认走，而不是被一条陈年记录钉死在旧状态。
  static const String homeQuickOverrides = 'ui.home_quick_overrides';

  /// 6.0.4 及更早的写法：只记"被收起了什么"（那时没有默认值这回事）。
  ///
  /// 保留它只为了迁移 —— 读一次、转成 `-[key]` 写进 [homeQuickOverrides]，
  /// 之后不再写它。删掉这段的后果老用户升级后会被自己关掉的插件全部冒出来。
  static const String homeQuickHidden = 'ui.home_quick_hidden';

  /// 上一次会话是否正常渲染过首页。
  ///
  /// 启动时写 `0`，首页真的呈现出来才写 `1`。下次启动读到 `0` = 上次没走完，
  /// 说明首页插件有可能把应用拖死了 —— 这是熔断唯一的判断依据。
  static const String sessionClean = 'sys.session_clean';

  /// 某个插件当首页失败的次数
  static String homeFailures(String pluginId) => 'sys.home_failures.$pluginId';

  /// 当前生效的货币由哪个插件提供（插件 id）；没有则为空。
  ///
  /// **第一个报告余额的插件自动成为当前货币** —— 不需要用户先去某处"启用"，
  /// 装完打开一次就生效，这是最省事的心智模型。
  static const String activeCurrency = 'ui.active_currency';

  /// 某个插件的货币余额**镜像**。
  ///
  /// 权威数据在插件自己的表里（流水求和），主包只存这一份用于画顶栏徽章 ——
  /// 否则每次重建界面都要去读插件的私有表，耦合且慢。
  /// 插件每次余额变化都要回报一次（见 bridge 的 `currency.set`）。
  static String currencyBalance(String pluginId) =>
      'currency.balance.$pluginId';

  /// 插件**最后一次被启用**的时刻（ISO-8601 UTC）。
  ///
  /// 停用期间不攒事件：桥的 `event.pending` 只投递这个时刻之后发生的事件。
  /// 没有这个键（从没停用过 / 全新安装）= 不做时间过滤，照旧全投。
  /// 前缀是 `plg.<id>.`，所以"删数据卸载"会连它一起清掉。
  static String pluginEnabledAt(String pluginId) =>
      'plg.$pluginId.enabled_at';

  /// 上一次成功拉到的插件索引原文（JSON）。
  ///
  /// 断网时用它，避免"打开插件市场一片空白"。放在 settings 表里而不是
  /// SharedPreferences，是为了跟数据库一起备份 —— 换机恢复后货架不退回出厂。
  static const String pluginIndexJson = 'plugins.index.json';

  /// 上面那份索引是什么时候拉到的（ISO-8601 UTC），界面用来写"显示 X 的索引"。
  static const String pluginIndexFetchedAt = 'plugins.index.fetched_at';
}

/// `settings` 表的读写。主包所有"用户开关"都走这里，
/// 这样它们会随数据库一起备份，而不是散落在 SharedPreferences 里。
class SettingsRepository {
  SettingsRepository(this._db);

  final Database _db;

  Future<String?> get(String key) async {
    final rows = await _db.query(
      V6Table.settings,
      columns: <String>[SettingsCol.value],
      where: '${SettingsCol.key} = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first[SettingsCol.value] as String?;
  }

  Future<void> set(String key, String value) async {
    await _db.insert(
      V6Table.settings,
      <String, Object?>{SettingsCol.key: key, SettingsCol.value: value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> getBool(String key, {required bool fallback}) async {
    final raw = await get(key);
    if (raw == null) return fallback;
    return raw == '1';
  }

  Future<void> setBool(String key, bool value) => set(key, value ? '1' : '0');

  Future<int> getInt(String key, {required int fallback}) async {
    final raw = await get(key);
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  Future<void> setInt(String key, int value) => set(key, '$value');

  /// 删掉某个插件在 settings 表里留下的**全部**键，返回删了几条。
  ///
  /// 插件会在这里留下三类键：
  /// - `plg.<id>.*` —— 插件自己的 KV（`store.set` 写的）
  /// - `currency.balance.<id>` —— 主包替它存的余额镜像
  /// - `sys.home_failures.<id>` —— 它当首页时失败过几次
  ///
  /// 只删表不清键的话，重装回来会看到一个**陈旧的余额**，
  /// 比"什么都没留下"更让人困惑 —— 明明数据删了，数字却还在。
  ///
  /// 前提是调用方已经不再需要这份数据（卸载时用户勾了"一起删掉"）。
  Future<int> erasePlugin(String pluginId) async {
    final prefix = 'plg.$pluginId.';
    // 前缀只用来缩小候选，判断仍用 startsWith：LIKE 里的 `_` 是单字符通配符，
    // 而插件 id **本身就带下划线**，`plg.a_b.%` 会误伤 `plg.axb.xxx`
    final candidates = await _db.query(
      V6Table.settings,
      columns: <String>[SettingsCol.key],
      where: '${SettingsCol.key} LIKE ?',
      whereArgs: <Object?>['$prefix%'],
    );
    final keys = <String>{
      for (final row in candidates)
        if ((row[SettingsCol.key] as String).startsWith(prefix))
          row[SettingsCol.key] as String,
      SettingsKeys.currencyBalance(pluginId),
      SettingsKeys.homeFailures(pluginId),
    };

    if (await get(SettingsKeys.activeCurrency) == pluginId) {
      keys.add(SettingsKeys.activeCurrency);
    }

    final placeholders = List<String>.filled(keys.length, '?').join(',');
    return _db.delete(
      V6Table.settings,
      where: '${SettingsCol.key} IN ($placeholders)',
      whereArgs: keys.toList(),
    );
  }
}
