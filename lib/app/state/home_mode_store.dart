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

  /// 用户对快捷切换的**显式选择**（存 `HomeMode.encode()`）。
  ///
  /// 默认值来自插件自己（manifest 的 `home`：声明了=显示，没声明=收起），
  /// 这里只记偏离默认的那部分：
  /// - [_quickOn]：默认收起、用户手动打开了
  /// - [_quickOff]：默认显示、用户手动收起了
  ///
  /// 为什么要分两个集合而不是存"最终可见集合"：插件会升级，默认值会变。
  /// 存最终集合的话，一条陈年记录会把插件的新默认值永远压住。
  final Set<String> _quickOn = <String>{};
  final Set<String> _quickOff = <String>{};

  HomeMode get mode => _mode;
  int get failures => _failures;
  bool get loaded => _loaded;

  /// 本次启动是否因为失败次数过多而被迫切回了内置
  bool get autoDowngraded => _autoDowngraded;

  /// 这个模式在顶栏的「快捷切换」里显示吗。
  ///
  /// 内置恒为真：插件把首页搞崩时，它是唯一的退路。
  bool isQuickVisible(HomeMode mode, {required bool defaultOn}) {
    if (mode.isBuiltin) return true;
    final key = mode.encode();
    if (_quickOff.contains(key)) return false;
    if (_quickOn.contains(key)) return true;
    return defaultOn;
  }

  /// 改快捷切换的显示状态。
  ///
  /// 两种模式**不允许**被收起，理由都不是"怕列表空"：
  /// - 内置：插件把首页搞崩时，这是唯一的退路；
  /// - 当前模式：弹层就是靠高亮当前项让用户知道"我现在在哪儿"，
  ///   把它藏掉，点开就是一堆没选中任何一项的选项，看着像坏了。
  ///
  /// 改回默认值时**把记录删掉**，而不是记一条"和默认一样"：
  /// 插件以后改了默认值，这条不该再压着它。
  Future<void> setQuickVisible(
    HomeMode mode,
    bool visible, {
    required bool defaultOn,
  }) async {
    if (mode.isBuiltin || mode == _mode) return;

    final key = mode.encode();
    _quickOn.remove(key);
    _quickOff.remove(key);
    if (visible != defaultOn) {
      (visible ? _quickOn : _quickOff).add(key);
    }

    notifyListeners();
    await _persistQuick();
  }

  Future<void> _persistQuick() async {
    final entries = <String>[
      for (final key in _quickOn) '+$key',
      for (final key in _quickOff) '-$key',
    ]..sort();
    await _settings.set(SettingsKeys.homeQuickOverrides, entries.join(','));
  }

  Future<void> load() async {
    final previousClean =
        await _settings.get(SettingsKeys.sessionClean) == '1';
    // 先写 0：接下来到首页真正呈现之前，任何异常退出都算"没渲染成功"
    await _settings.set(SettingsKeys.sessionClean, '0');

    _mode = HomeMode.parse(await _settings.get(SettingsKeys.homeMode));
    _failures = 0;
    _autoDowngraded = false;

    _quickOn.clear();
    _quickOff.clear();
    final raw = await _settings.get(SettingsKeys.homeQuickOverrides);
    if (raw == null) {
      // 6.0.4 及更早只记"收起了什么"。迁移成显式的"关掉"，
      // 否则老用户升级后，自己关掉过的插件会全部重新冒出来。
      final legacy = await _settings.get(SettingsKeys.homeQuickHidden) ?? '';
      _quickOff.addAll(
        legacy.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    } else {
      for (final token in raw.split(',')) {
        final item = token.trim();
        if (item.length < 2) continue;
        final key = item.substring(1);
        if (item[0] == '+') {
          _quickOn.add(key);
        } else if (item[0] == '-') {
          _quickOff.add(key);
        }
      }
    }

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
  ///
  /// 顺手把它在快捷切换里的记录清掉：这个包都没了，留着一条只会在
  /// 用户重装同名插件时，让新插件的默认值莫名其妙地失效。
  Future<void> onPluginUninstalled(String pluginId) async {
    final key = HomeMode.plugin(pluginId).encode();
    final touched = _quickOn.remove(key) | _quickOff.remove(key);
    if (touched) await _persistQuick();

    if (_mode.pluginId != pluginId) {
      if (touched) notifyListeners();
      return;
    }
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
