import 'dart:async';
import 'dart:convert';

import '../../core/plugin/plugin_index.dart';
import '../../core/services/remote_text.dart';
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

  /// 并发拉所有候选源，**挑 `publishedAt` 最新的那份**。
  ///
  /// 为什么不能"第一个成功就用"：jsDelivr 对 `@main` 的解析结果是缓存的，
  /// 某个节点可能还在发旧索引（purge 也不一定刷得掉，实测 gcore 就这样）。
  /// 而客户端是**按顺序取第一个成功的** —— 表现的正是"我明明发了新插件，
  /// 用户看不到，可我自己用浏览器访问 raw 明明是新的"。
  ///
  /// 所以改成：并发拿几份，谁的时间戳新用谁。单源失败不影响其它源。
  static Future<String> fetchNewestIndex(
    List<Uri> candidates, {
    Uri? contentsApi,
    Duration timeout = const Duration(seconds: 8),
    Duration grace = const Duration(milliseconds: 600),
    IndexTextFetcher? fetch,
  }) async {
    final doFetch = fetch ??
        (Uri uri, {required bool viaContentsApi, required Duration timeout}) =>
            RemoteText.fetch(uri, viaContentsApi: viaContentsApi, timeout: timeout);

    final sources = <(Uri, bool)>[
      for (final candidate in candidates) (candidate, false),
      if (contentsApi != null) (contentsApi, true),
    ];
    if (sources.isEmpty) throw const RemoteTextException('没有可用的索引地址');

    final arrived = <String>[];
    final firstOk = Completer<void>();
    final allDone = Completer<void>();
    var left = sources.length;

    for (final (uri, viaApi) in sources) {
      unawaited(() async {
        try {
          final text = await doFetch(uri, viaContentsApi: viaApi, timeout: timeout);
          arrived.add(text);
          if (!firstOk.isCompleted) firstOk.complete();
        } catch (_) {
          // 单个源失败不该拖垮整次拉取
        } finally {
          left--;
          if (left == 0 && !allDone.isCompleted) allDone.complete();
        }
      }());
    }

    // 等到"至少一个成功"或"全部结束"；再多等一小会儿 —— 否则拿到的只是
    // "响应最快的那个"，不等于"最新的那个"。
    await Future.any<void>(<Future<void>>[firstOk.future, allDone.future]);
    await Future.any<void>(<Future<void>>[
      allDone.future,
      Future<void>.delayed(grace),
    ]);

    if (arrived.isEmpty) {
      throw const RemoteTextException('所有源都失败了');
    }
    return arrived.reduce((a, b) {
      final ta = _publishedAtOf(a);
      final tb = _publishedAtOf(b);
      return tb.isAfter(ta) ? b : a;
    });
  }

  static DateTime _publishedAtOf(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['publishedAt'] is String) {
        return DateTime.tryParse(decoded['publishedAt'] as String) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
    } catch (_) {
      // 不是合法 JSON 的源按"最旧"处理，反正解析阶段会再拦一次
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  static PluginIndex _parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const PluginFormatException('索引顶层必须是对象');
    }
    return PluginIndex.parse(Map<String, Object?>.from(decoded));
  }
}

/// 拉取一份索引原文。抽成 typedef 是为了让"多镜像取最新"这段能单测。
typedef IndexTextFetcher = Future<String> Function(
  Uri uri, {
  required bool viaContentsApi,
  required Duration timeout,
});
