import 'dart:convert';

import '../../config/cdn_bases.dart';
import '../../services/remote_text.dart';
import '../../utils/app_logger.dart';
import '../models/app_update_decision.dart';
import '../models/app_update_manifest.dart';
import 'app_update_decider.dart';
import 'app_update_exception.dart';

/// App 版本检查：拉取云端 `update.json` 并给出更新结论。
///
/// 与游戏模块共用同一套 CDN 基址与「主站优先、镜像回退」策略（见 [CdnBases]），
/// 因此**不需要任何后端**——把 `update.json` 提交到仓库根目录即可生效。
///
/// 职责边界：本类只负责「拉取 + 交给决策器判定」，不负责下载安装包、
/// 不做持久化、不弹 UI。那些是上层的事。
class AppUpdateService {
  /// 本仓库的更新清单文件名。
  ///
  /// 分仓之后它就是 V6 唯一的清单。**V5 的 `update.json` 在另一个仓库里**
  /// （`Aria-2676/note_study`），两份文件同名但互不相干。
  static const String defaultManifestPath = 'update.json';

  /// GitHub Contents API 上的仓库内容地址前缀。
  static const String contentsApiBase =
      'https://api.github.com/repos/Aria-2676/taskmaster-v6/contents';

  AppUpdateService({
    this.manifestPath = defaultManifestPath,
    List<Uri> Function()? candidateProvider,
    Uri? contentsApiUrl,
    this.timeout = const Duration(seconds: 15),
  }) : _candidateProvider =
           candidateProvider ?? (() => candidatesFor(manifestPath)),
       _contentsApiUrl = contentsApiUrl ?? contentsApiUri(manifestPath);

  /// 这份 service 读哪份清单。
  ///
  /// 由 [UpdateChannel.current] 决定；直接 new 的时候就是仓库根目录那份。
  final String manifestPath;

  final List<Uri> Function() _candidateProvider;

  /// Contents API 兜底地址（可注入仅为测试）。
  final Uri _contentsApiUrl;

  /// 单次 HTTP 请求的超时时间。
  final Duration timeout;

  /// 默认候选地址：主 CDN 在前，镜像在后，自动去重。
  static List<Uri> candidatesFor(String path) {
    return CdnBases.resolve(CdnBases.manifest, CdnBases.manifestFallbacks, path);
  }

  /// Contents API 地址。**必须跟着清单名走** ——
  /// 否则 V6 在 CDN 全部失败时会去读 V5 的清单，把 5.x 的更新当成自己的。
  static Uri contentsApiUri(String path) =>
      Uri.parse('$contentsApiBase/$path');

  /// 兼容旧调用点（默认渠道）。
  static List<Uri> defaultCandidates() => candidatesFor(defaultManifestPath);

  /// 按候选顺序依次尝试拉取更新清单。
  ///
  /// 顺序：jsDelivr 各节点（gcore → testingcf → cdn）→ raw 源站 →
  /// GitHub Contents API（近实时，限速兜底）。单个候选失败只记日志并继续，
  /// 这样某个节点抽风不会让功能整体不可用；全部失败才抛 [AppUpdateException]。
  Future<AppUpdateManifest> fetchManifest() async {
    Object? lastError;
    for (final uri in _candidateProvider()) {
      try {
        final body = await _httpGetString(uri, viaContentsApi: false);
        return AppUpdateManifest.fromJson(jsonDecode(body));
      } catch (error, stack) {
        lastError = error;
        AppLogger.warn('AppUpdateService', '获取更新清单失败: $uri', error, stack);
      }
    }

    // 最后一路：GitHub Contents API（JSON 信封里装 base64 内容）。
    try {
      final body = await _httpGetString(
        _contentsApiUrl,
        viaContentsApi: true,
      );
      return AppUpdateManifest.fromJson(jsonDecode(body));
    } catch (error, stack) {
      lastError = error;
      AppLogger.warn(
        'AppUpdateService',
        '获取更新清单失败（Contents API）: $_contentsApiUrl',
        error,
        stack,
      );
    }

    throw AppUpdateException('无法获取更新清单（$lastError）');
  }

  /// 拉取失败时返回 null。
  ///
  /// 版本检查是「锦上添花」，网络异常时应当静默跳过，而不是把错误抛给用户。
  Future<AppUpdateManifest?> tryFetchManifest() async {
    try {
      return await fetchManifest();
    } on AppUpdateException {
      return null;
    }
  }

  /// 一次完整的版本检查：拉清单 → 决策。
  ///
  /// 参数含义见 [AppUpdateDecider.decide]。
  Future<AppUpdateDecision> check({
    required String currentVersion,
    required String platform,
    int currentAssetBuild = 0,
    String? ignoredVersion,
    bool notificationsDisabled = false,
  }) async {
    final manifest = await tryFetchManifest();
    return AppUpdateDecider.decide(
      manifest: manifest,
      currentVersion: currentVersion,
      platform: platform,
      currentAssetBuild: currentAssetBuild,
      ignoredVersion: ignoredVersion,
      notificationsDisabled: notificationsDisabled,
    );
  }

  /// 拉取并解码清单文本。
  ///
  /// [viaContentsApi] 为 true 时，响应是 GitHub Contents API 的 JSON 信封
  /// （`{encoding: "base64", content: "..."}`），需要先拆信封、base64 解码；
  /// 为 false 时响应体就是清单原文。
  ///
  /// 所有请求都带 `Cache-Control: no-cache`：中间透明缓存（运营商/企业网关）
  /// 不得缓存清单，尽量缩短「发布 → 客户端发现」的延迟。
  Future<String> _httpGetString(Uri uri, {required bool viaContentsApi}) async {
    // 具体怎么拉、Contents API 的信封怎么解，统一在 RemoteText 里 —
    // 插件索引也用它，那段 base64 剥换行的逻辑不能有两份。
    try {
      return await RemoteText.fetch(
        uri,
        viaContentsApi: viaContentsApi,
        timeout: timeout,
      );
    } on RemoteTextException catch (error) {
      throw AppUpdateException(error.message);
    }
  }
}
