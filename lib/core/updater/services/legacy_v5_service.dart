import '../models/app_update_manifest.dart';
import 'app_update_service.dart';

/// 读 **5.x 那边**的更新清单，用来知道"对方现在最新是哪一版"。
///
/// 为什么入口不该写死版本号：写死意味着每改一次就要两边各发一版 ——
/// 而"对方最新是多少"这件事，只有对方的清单知道。改成读对方的
/// `update.json` 之后：
///
/// - V5 发 5.5.29、5.5.30……V6 这边**不用动**，用户点进去拿到的就是那个新版
/// - 仍然带 sha256 校验（清单里本来就写了每个包的摘要），也仍然按 ABI 选包
/// - 读不到才回落写死的已知可用版本（[LegacyV5Link]），功能不会消失
///
/// 清单在 `note_study` 仓库根目录，与 V6 自己那份同名但不同仓库，
/// 所以候选地址要在这里单独拼（[CdnBases] 里写死的是 V6 仓库）。
class LegacyV5Service {
  const LegacyV5Service._();

  static const String repo = 'Aria-2676/note_study';
  static const String manifestPath = 'update.json';

  /// jsDelivr 各节点 + raw 直连。
  ///
  /// **必须多源**：某个节点缓存滞后时，只信一个源就会把旧版本当成"最新"。
  /// `AppUpdateService.fetchManifest` 会并发全取、按 `updatedAt` 挑最新，
  /// 所以这里的顺序只影响耗时，不影响结论。
  static List<Uri> candidates() => <Uri>[
        for (final host in const <String>[
          'gcore.jsdelivr.net',
          'testingcf.jsdelivr.net',
          'fastly.jsdelivr.net',
          'cdn.jsdelivr.net',
        ])
          Uri.parse('https://$host/gh/$repo@main/$manifestPath'),
        Uri.parse('https://raw.githubusercontent.com/$repo/main/$manifestPath'),
      ];

  static Uri contentsApi() =>
      Uri.parse('https://api.github.com/repos/$repo/contents/$manifestPath');

  static AppUpdateService service() => AppUpdateService(
        manifestPath: manifestPath,
        candidateProvider: candidates,
        contentsApiUrl: contentsApi(),
      );

  /// 读对方的清单。失败返回 null（调用方回落到写死的版本）。
  ///
  /// 刻意**不抛**：这是"顺带看一眼最新版"，读不到不该让用户看不到下载入口。
  static Future<AppUpdateManifest?> fetch() => service().tryFetchManifest();

  /// 从清单里挑出适合当前机型的下载目标；挑不到返回 null。
  static AppDownloadTarget? targetFor(
    AppUpdateManifest? manifest, {
    required String platform,
    String? abi,
  }) =>
      manifest?.release?.resolveTarget(platform, abi: abi);
}
