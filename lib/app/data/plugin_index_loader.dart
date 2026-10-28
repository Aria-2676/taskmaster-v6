import 'dart:convert';

import '../../core/plugin/plugin_index.dart';
import '../../core/plugin/plugin_manifest.dart';
import 'settings_repository.dart';

/// 这份索引是从哪儿来的。界面靠它决定状态行怎么写。
enum PluginIndexSource {
  /// 刚从网上拉到
  remote,

  /// 网没通，用的是上次拉下来存着的
  cache,

  /// 连缓存都没有，用的是随 App 打进去的那份
  bundled,
}

class PluginIndexResult {
  const PluginIndexResult({
    required this.index,
    required this.source,
    this.fetchedAt,
    this.remoteError,
  });

  /// 测试里造"就这一份索引"用
  factory PluginIndexResult.bundled(PluginIndex index) => PluginIndexResult(
        index: index,
        source: PluginIndexSource.bundled,
      );

  final PluginIndex index;
  final PluginIndexSource source;

  /// 这份索引是什么时候从网上拿到的。bundled 时为 null —— 它没有"拿到时间"，
  /// 只有"跟着哪个 App 版本发出去"。
  final DateTime? fetchedAt;

  /// 远端失败的原始错误。降级到 cache / bundled 时带上，界面可以露出来。
  final String? remoteError;
}

/// 插件索引的加载策略：**远端 → 本地缓存 → 随包的兜底**。
///
/// 为什么不是"拉不到就只显示已装"：远端决定货架新不新，缓存决定断网还能不能
/// 装已知的插件，随包那份决定"从没联过网的第一次启动也不空白"。三级都留着，
/// 代价是随包那份可能过时（会显示一个已被删掉的插件，点了装失败）——
/// 比"打开市场什么都没有"好接受。
///
/// 缓存落在 settings 表而不是 SharedPreferences：它跟着数据库一起备份，
/// 换机恢复数据之后货架不会退回出厂状态。
///
/// 放在 `app/data/` 而不是 `core/`：它要用 `SettingsRepository`，
/// 而 core 不许依赖 app 层（`PluginBridge` 也在这层，同一个理由）。
class PluginIndexLoader {
  PluginIndexLoader({
    required Future<String> Function() fetchRemote,
    required Future<String> Function() loadBundled,
    required SettingsRepository settings,
  })  : _fetchRemote = fetchRemote,
        _loadBundled = loadBundled,
        _settings = settings;

  final Future<String> Function() _fetchRemote;
  final Future<String> Function() _loadBundled;
  final SettingsRepository _settings;

  /// 最近一次加载的结果（界面读来源 / 时间）
  PluginIndexResult? last;

  Future<PluginIndexResult> load() async {
    String? remoteError;

    try {
      final text = await _fetchRemote();
      final index = _parse(text);
      final now = DateTime.now().toUtc();
      try {
        // 先落缓存再返回：下次断网要能拿到"上一次真正可用的那份"。
        // 写缓存失败不该让这次加载失败，只是下次断网会退到 bundled。
        await _settings.set(SettingsKeys.pluginIndexJson, text);
        await _settings.set(
          SettingsKeys.pluginIndexFetchedAt,
          now.toIso8601String(),
        );
      } catch (_) {
        // 见上
      }
      return last = PluginIndexResult(
        index: index,
        source: PluginIndexSource.remote,
        fetchedAt: now,
      );
    } catch (error) {
      remoteError = '$error';
    }

    final cached = await _settings.get(SettingsKeys.pluginIndexJson);
    if (cached != null && cached.trim().isNotEmpty) {
      try {
        final at = await _settings.get(SettingsKeys.pluginIndexFetchedAt);
        return last = PluginIndexResult(
          index: _parse(cached),
          source: PluginIndexSource.cache,
          fetchedAt: at == null ? null : DateTime.tryParse(at),
          remoteError: remoteError,
        );
      } catch (_) {
        // 缓存坏了（升级改了格式等）就当没有，继续往下退
      }
    }

    return last = PluginIndexResult(
      index: _parse(await _loadBundled()),
      source: PluginIndexSource.bundled,
      remoteError: remoteError,
    );
  }

  static PluginIndex _parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const PluginFormatException('索引顶层必须是对象');
    }
    return PluginIndex.parse(Map<String, Object?>.from(decoded));
  }
}
