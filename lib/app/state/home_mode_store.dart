import 'package:flutter/foundation.dart';

import '../../core/home/home_mode.dart';
import '../data/settings_repository.dart';

/// 首页形态的状态 + **熔断**。
///
/// 可换首页有一个天生的问题：插件把启动拖死时，用户没有界面可用
/// （连"切回内置"都点不到）。所以这套熔断必须在**渲染之前**就能生效，
/// 判断依据只有一条：上次会话有没有走到"首页渲染成功"。
///
/// 三个触发点：
///   1. 上次没渲染成功（[load] 里检查）→ 记一次失败
///   2. 本次首帧超时 / 加载报错（[reportFailure]）→ 记一次失败
///   3. 失败累计到 [maxFailures] → **自动切回内置并落库**
///
/// 计数在渲染成功后清零（[markRendered]），所以偶发的一次崩溃不会
/// 把用户的首页永久换掉。
class HomeModeStore extends ChangeNotifier {
  HomeModeStore(this._settings, {this.maxFailures = 2});

  final SettingsRepository _settings;

  /// 连续失败几次就自动降级
  final int maxFailures;

  HomeMode _mode = const HomeMode.builtin();
  int _failures = 0;
  bool _autoDowngraded = false;
  bool _loaded = false;

  HomeMode get mode => _mode;
  int get failures => _failures;
  bool get loaded => _loaded;

  /// 本次启动是否因为失败次数过多而被迫切回了内置
  bool get autoDowngraded => _autoDowngraded;

  Future<void> load() async {
    final previousClean =
        await _settings.get(SettingsKeys.sessionClean) == '1';
    // 先写 0：接下来到首页真正呈现之前，任何异常退出都算"没渲染成功"
    await _settings.set(SettingsKeys.sessionClean, '0');

    _mode = HomeMode.parse(await _settings.get(SettingsKeys.homeMode));
    _failures = 0;
    _autoDowngraded = false;

    final id = _mode.pluginId;
    if (id != null) {
      _failures = await _settings.getInt(
        SettingsKeys.homeFailures(id),
        fallback: 0,
      );
      if (!previousClean) {
        _failures += 1;
        await _settings.setInt(SettingsKeys.homeFailures(id), _failures);
        if (_failures >= maxFailures) {
          await _downgrade(id);
        }
      }
    }

    _loaded = true;
    notifyListeners();
  }

  /// 首页真的呈现出来了。**这是清零的唯一时机** ——
  /// 只在启动时清，会把"每次都能启动但一用就崩"的情况漏过去。
  Future<void> markRendered() async {
    await _settings.set(SettingsKeys.sessionClean, '1');
    final id = _mode.pluginId;
    if (id == null || _failures == 0) return;
    _failures = 0;
    await _settings.setInt(SettingsKeys.homeFailures(id), 0);
    notifyListeners();
  }

  /// 这一次加载失败了（超时 / 抛错 / 插件不在）。返回是否因此自动降级。
  Future<bool> reportFailure() async {
    final id = _mode.pluginId;
    if (id == null) return false;

    _failures += 1;
    notifyListeners();
    await _settings.setInt(SettingsKeys.homeFailures(id), _failures);

    if (_failures >= maxFailures) {
      await _downgrade(id);
      return true;
    }
    return false;
  }

  /// 用户显式选择。切换会清掉新模式的失败计数 ——
  /// 否则用户手动切回来后第一次小故障就又被踢走。
  Future<void> setMode(HomeMode mode) async {
    _mode = mode;
    _failures = 0;
    _autoDowngraded = false;
    notifyListeners();
    await _settings.set(SettingsKeys.homeMode, mode.encode());
    final id = mode.pluginId;
    if (id != null) {
      await _settings.setInt(SettingsKeys.homeFailures(id), 0);
    }
  }

  /// 插件被卸载了。当选首页的那个没了，必须回到内置，
  /// 不然下次启动会对着一个不存在的插件重试两次才降级。
  Future<void> onPluginUninstalled(String pluginId) async {
    if (_mode.pluginId != pluginId) return;
    await setMode(const HomeMode.builtin());
  }

  Future<void> _downgrade(String pluginId) async {
    _mode = const HomeMode.builtin();
    _autoDowngraded = true;
    notifyListeners();
    await _settings.set(SettingsKeys.homeMode, _mode.encode());
    // 计数不清零：设置页要靠它显示"上次失败了几次，所以切回来了"
    await _settings.setInt(SettingsKeys.homeFailures(pluginId), _failures);
  }
}
