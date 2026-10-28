import 'package:flutter/foundation.dart';

import '../../core/plugin/plugin_index.dart';
import '../../core/plugin/plugin_installer.dart';
import '../../core/plugin/plugin_manifest.dart';
import '../../core/plugin/plugin_store.dart';
import '../../core/utils/version_utils.dart';
import '../data/settings_repository.dart';

/// 插件市场的状态。
///
/// 分成两件独立的事：**已安装列表来自本地库（不会失败）**，
/// **可安装列表来自索引（可能失败）**。索引拿不到时页面仍然可用 ——
/// 至少用户能看到自己装了什么、能卸载。
class PluginMarketStore extends ChangeNotifier {
  PluginMarketStore({
    required PluginInstaller installer,
    required Future<PluginIndex> Function() indexLoader,
    required Uri Function(PluginPackage package) urlFor,
    this.onInstalled,
    this.onUninstalled,
    this.onEnabledChanged,
  })  : _installer = installer,
        _indexLoader = indexLoader,
        _urlFor = urlFor;

  final PluginInstaller _installer;
  final Future<PluginIndex> Function() _indexLoader;
  final Uri Function(PluginPackage package) _urlFor;

  /// 安装成功后回调（参数是索引条目，含权限声明）。
  ///
  /// 用途是"装完立刻生效"：声明了 `currency:write` 的插件装上就该在顶栏
  /// 出现一个 0，而不是等用户点进去打开一次才有反应。
  final void Function(PluginIndexEntry entry)? onInstalled;

  /// 卸载成功后回调。
  ///
  /// 卸载会留下指向它的**持久化状态**：`ui.home_mode` 可能指着它当首页、
  /// `ui.active_currency` 可能指着它当货币提供者。不通知的话这两处会
  /// 一直指向一个已经不存在的插件 —— 表现是「首页模式」页打开后没有任何
  /// 一项被选中，顶栏货币则靠"再查一次已装列表"临时兜住。
  final void Function(String pluginId)? onUninstalled;

  /// 停用 / 启用之后回调。
  ///
  /// 停用是**完全停机**：入口、事件、首页、货币位全撤。其中首页与货币位是
  /// 持久化指针（`ui.home_mode` / `ui.active_currency`），必须由应用层改，
  /// 状态层不能自己去碰这两个 store。启用时反向把货币位接回来
  /// （`ensureProvider` 用镜像里的旧余额，不会清成 0）。
  final void Function(String pluginId, bool enabled)? onEnabledChanged;

  /// 设置表：删数据卸载时要用它清插件留下的键
  late final SettingsRepository _settings = SettingsRepository(_installer.db);

  PluginIndex index = PluginIndex.empty;
  List<InstalledPlugin> installed = const <InstalledPlugin>[];
  bool loading = true;

  /// 索引获取失败的原因。已安装部分不受它影响。
  String? indexError;

  /// 安装/卸载失败的原因，页面显示一次后清掉
  String? lastError;

  final Map<String, double> _progress = <String, double>{};

  PluginInstaller get installer => _installer;

  /// 0..1，null 表示没有正在进行的安装
  double? progressOf(String pluginId) => _progress[pluginId];

  bool isInstalled(String pluginId) =>
      installed.any((p) => p.pluginId == pluginId);

  /// 停用中的插件对**外壳**不可见：侧边栏入口、首页候选、货币位都不给它。
  ///
  /// 市场页仍然用 [installed]（用户得看得见它、把它开回来）。
  /// 两个列表分开，是为了让"停用"只有一个判据（`enabled` 字段），
  /// 而不是每个调用点各自记得过滤一次 —— 漏一处就是"停用了还占着位置"。
  List<InstalledPlugin> get active =>
      installed.where((p) => p.enabled).toList(growable: false);

  /// 索引里有、但还没装的
  List<PluginIndexEntry> get available =>
      index.plugins.where((e) => !isInstalled(e.id)).toList();

  /// 这个已安装插件在索引里有没有新版本。
  ///
  /// 没有升级通道的话，用户想升只能卸载重装 —— 而卸载会把它自己的
  /// 数据（表、KV）一起清掉。覆盖安装（`PluginInstaller.install` 对
  /// 已有 id 是 upsert + 清旧版本目录）数据都在，所以升级 =
  /// 对新条目走一遍 install。
  ///
  /// 契约不支持的条目不当作升级（`installable` 为 false，装了也装不上）。
  PluginIndexEntry? updateFor(InstalledPlugin item) {
    final entry = index.findById(item.pluginId);
    if (entry == null || !entry.installable) return null;
    return VersionUtils.isNewer(entry.version, item.version) ? entry : null;
  }

  void clearError() {
    if (lastError == null) return;
    lastError = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();

    // 本地库先读：这一步不会失败，先让"已安装"有内容
    installed = await _installer.store.all();

    try {
      index = await _indexLoader();
      indexError = null;
    } catch (error) {
      index = PluginIndex.empty;
      indexError = '$error';
    }

    loading = false;
    notifyListeners();
  }

  Future<void> install(PluginIndexEntry entry) async {
    if (_progress.containsKey(entry.id)) return;

    // 升级 = 对已装插件再走一遍 install。首次安装才需要 onInstalled
    // （报余额 0 / 点亮徽章）；升级时镜像和数据都在，再报 0 会把
    // 用户攒的余额清掉。
    final isUpdate = isInstalled(entry.id);

    _progress[entry.id] = 0;
    lastError = null;
    notifyListeners();

    try {
      await _installer.install(
        entry,
        packageUrl: _urlFor(entry.package),
        onProgress: (value) {
          _progress[entry.id] = value.clamp(0.0, 1.0);
          notifyListeners();
        },
      );
      if (!isUpdate) onInstalled?.call(entry);
    } on PluginInstallException catch (error) {
      lastError = error.message;
      rethrow;
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      _progress.remove(entry.id);
      installed = await _installer.store.all();
      notifyListeners();
    }
  }

  /// 停用 / 启用。
  ///
  /// 顺序：**先撤外壳上的指针（onEnabledChanged）→ 再落库**，和卸载一致：
  /// 反过来在中间那一瞬界面还按"它还在"渲染。
  Future<void> setEnabled(String pluginId, bool enabled) async {
    if (!isInstalled(pluginId)) return;
    lastError = null;
    try {
      onEnabledChanged?.call(pluginId, enabled);
      await _installer.store.setEnabled(pluginId, enabled);
      if (enabled) {
        // 启用时刻的戳：停用期间的事件不补发（见 SettingsKeys.pluginEnabledAt）
        await _settings.set(
          SettingsKeys.pluginEnabledAt(pluginId),
          DateTime.now().toUtc().toIso8601String(),
        );
      }
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      installed = await _installer.store.all();
      notifyListeners();
    }
  }

  /// 卸载。[keepData] 为 false 时连插件自己的表和设置键一起清掉。
  ///
  /// 顺序：**先改持久化的指针（onUninstalled）→ 再删数据**。
  /// 反过来的话 `erasePlugin` 会把 `ui.active_currency` 删掉，接着
  /// `CurrencyStore` 又把它写回成空串 —— 结果一样但多一次写。
  Future<void> uninstall(String pluginId, {bool keepData = true}) async {
    lastError = null;
    notifyListeners();

    try {
      await _installer.uninstall(pluginId, keepData: keepData);
      // 内存里的"谁是首页 / 谁是货币"必须跟着变，否则界面还按老状态渲染
      onUninstalled?.call(pluginId);
      if (!keepData) await _settings.erasePlugin(pluginId);
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      installed = await _installer.store.all();
      notifyListeners();
    }
  }
}
