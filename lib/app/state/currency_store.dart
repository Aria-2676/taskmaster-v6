import 'package:flutter/foundation.dart';

import '../../core/extension/extension_slot.dart';
import '../data/settings_repository.dart';

/// 「当前货币」的余额，以及它由哪个插件提供。
///
/// ## 为什么是专用通道，不是通用插槽
///
/// `SlotRegistry` 本来就规划了「WebView 插件经 bridge 提供插槽值」，
/// 但通用方案要同时解决四件事：序列化、按插槽的类型校验、多提供者优先级、
/// 值的持久化。而目前**只有货币**这一个真实需求。
///
/// 所以这里走一条窄通道：一个整数 + 一个插件 id。
/// 等出现第二个"要占外壳位置"的插件（比如待办计数、天气），
/// 再把这条通道抽象成通用的，那时才知道该抽象成什么样。
///
/// ## 谁是"当前货币"
///
/// 第一个报告余额的插件自动成为当前货币。装完打开一次就生效，
/// 不需要用户先去某个设置页"启用"——少一步就少一步放弃的机会。
/// 之后别的插件报告余额只会存下来，不会抢走显示位。
class CurrencyStore extends ChangeNotifier implements SlotProvider {
  CurrencyStore(this._settings);

  final SettingsRepository _settings;

  String? _providerId;
  int _balance = 0;

  /// 提供货币的插件 id（null = 没有）
  String? get providerId => _providerId;

  int get balance => _balance;

  bool get installed => _providerId != null;

  Future<void> load() async {
    _providerId = await _settings.get(SettingsKeys.activeCurrency);
    final id = _providerId;
    _balance = id == null
        ? 0
        : await _settings.getInt(
            SettingsKeys.currencyBalance(id),
            fallback: 0,
          );
    notifyListeners();
  }

  /// 读某个插件的余额镜像（没记录就是 0）。
  Future<int> balanceOf(String pluginId) =>
      _settings.getInt(SettingsKeys.currencyBalance(pluginId), fallback: 0);

  /// 插件报告自己的余额。
  ///
  /// 无论它是不是当前货币，镜像都会更新 —— 否则用户以后切换货币时
  /// 会看到一个陈旧的数字。只有当前货币的数字才会出现在顶栏。
  Future<void> report(String pluginId, int amount) async {
    await _settings.setInt(SettingsKeys.currencyBalance(pluginId), amount);

    if (_providerId == null) {
      _providerId = pluginId;
      await _settings.set(SettingsKeys.activeCurrency, pluginId);
    }
    if (_providerId != pluginId) return;

    _balance = amount;
    notifyListeners();
  }

  /// 刚装上一个声明了 `currency:write` 的插件时点亮顶栏徽章。
  ///
  /// **和 [report] 的区别**：这里不写余额，只"接手"。
  /// - 没有历史镜像（真·首次安装）→ 写 0，让用户立刻看到一个徽章，
  ///   而不是"装完了什么都没发生"。
  /// - 有历史镜像（卸载时选了保留数据，又装回来）→ 用旧值显示，
  ///   绝不盖成 0。插件自己的表里余额还在，盖 0 等于显示一个假的数字；
  ///   等用户打开插件，它会用真实余额再 report 一次。
  Future<void> ensureProvider(String pluginId) async {
    final existing = await _settings.get(SettingsKeys.currencyBalance(pluginId));
    if (existing == null) {
      await report(pluginId, 0);
      return;
    }

    if (_providerId == null) {
      _providerId = pluginId;
      await _settings.set(SettingsKeys.activeCurrency, pluginId);
    }
    if (_providerId != pluginId) return; // 已经有别的货币在位，不抢

    _balance = int.tryParse(existing) ?? 0;
    notifyListeners();
  }

  /// 用户手动指定当前货币（`null` = 不要货币）。
  Future<void> select(String? pluginId) async {
    if (pluginId == null) {
      _providerId = null;
      _balance = 0;
      await _settings.set(SettingsKeys.activeCurrency, '');
      notifyListeners();
      return;
    }
    _providerId = pluginId;
    _balance = await balanceOf(pluginId);
    await _settings.set(SettingsKeys.activeCurrency, pluginId);
    notifyListeners();
  }

  /// 插件被卸载：它提供的货币要跟着失效，否则顶栏会一直挂着一个
  /// 已经没人维护的数字。
  Future<void> onPluginUninstalled(String pluginId) async {
    if (_providerId != pluginId) return;
    _providerId = null;
    _balance = 0;
    await _settings.set(SettingsKeys.activeCurrency, '');
    notifyListeners();
  }

  // ---- SlotProvider：让现有的顶栏徽章直接复用 ----

  @override
  String get pluginId => 'host.currency';

  @override
  Set<SlotId> get slots => const <SlotId>{SlotId.currencyBadge};

  @override
  SlotValue? provide(SlotId slot, Map<String, Object?> context) =>
      _providerId == null ? null : CurrencyBadgeValue(value: _balance);
}
