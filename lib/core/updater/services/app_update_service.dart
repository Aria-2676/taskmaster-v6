import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

  /// 拉更新清单：并发取多份，**挑 `updatedAt` 最新的那份**。
  ///
  /// 不能"第一个成功就用"——CDN 会缓存分支解析出来的旧提交（gcore 实测会
  /// 持续发旧文件），而最快响应的那个恰恰可能是旧的，表现就是"明明发了新版，
  /// 用户那边一直提示已是最新"。
  Future<AppUpdateManifest> fetchManifest() async {
    try {
      final body = await RemoteText.fetchNewest(
        _candidateProvider(),
        contentsApi: _contentsApiUrl,
        timeout: timeout,
        freshnessOf: manifestFreshness,
        onFailure: (uri, error) => AppLogger.warn(
          'AppUpdateService',
          '获取更新清单失败: $uri',
          error,
          null,
        ),
      );
      return AppUpdateManifest.fromJson(jsonDecode(body));
    } on RemoteTextException catch (error) {
      throw AppUpdateException('无法获取更新清单（${error.message}）');
    }
  }

  /// 清单里的生成时间。读不出来按"最旧"处理（老清单没有这个字段）。
  ///
  /// 暴露出来是为了能单测：这行 parse 错了不会崩，只会让"取最新"退化成
  /// "随便取一个"，属于最难查的那类。
  @visibleForTesting
  static DateTime manifestFreshness(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['updatedAt'] is String) {
        return DateTime.tryParse(decoded['updatedAt'] as String) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
    } catch (_) {
      // 坏 JSON 交给解析阶段报错
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
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
}
