import 'package:flutter/foundation.dart';

import '../../core/plugin/plugin_index.dart';
import '../../core/plugin/plugin_installer.dart';
import '../../core/plugin/plugin_manifest.dart';
import '../../core/plugin/plugin_store.dart';

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
  })  : _installer = installer,
        _indexLoader = indexLoader,
        _urlFor = urlFor;

  final PluginInstaller _installer;
  final Future<PluginIndex> Function() _indexLoader;
  final Uri Function(PluginPackage package) _urlFor;

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

  /// 索引里有、但还没装的
  List<PluginIndexEntry> get available =>
      index.plugins.where((e) => !isInstalled(e.id)).toList();

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

  Future<void> uninstall(String pluginId) async {
    lastError = null;
    notifyListeners();

    try {
      await _installer.uninstall(pluginId);
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      installed = await _installer.store.all();
      notifyListeners();
    }
  }
}
