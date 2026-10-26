import '../../utils/version_utils.dart';
import '../models/app_update_decision.dart';
import '../models/app_update_manifest.dart';

/// 版本检查的决策逻辑。
///
/// 刻意做成**无副作用纯函数**：不读磁盘、不发网络、不碰 SharedPreferences。
/// 「用户跳过过哪个版本」「是否关掉了提醒」都由调用方作为参数传进来，
/// 这样这段最容易出错的判定逻辑可以直接被单元测试全覆盖。
class AppUpdateDecider {
  const AppUpdateDecider._();

  /// 判定当前应该做什么。
  ///
  /// - [manifest] 为 null 表示清单没拉到（网络失败等）→ 静默返回无更新，
  ///   绝不在网络异常时打扰用户。
  /// - [platform] 取 `android` / `ios` / `windows` 等，用于挑选整包产物；
  ///   清单没提供该平台产物时视为无整包更新（例如只发了 Android 包）。
  /// - [abi] 可选的应用 ABI（如 `arm64-v8a`）。提供时会优先匹配
  ///   `<platform>-<abi>` 这类细分产物，匹配不到再回落到 `<platform>` 泛化产物。
  ///   这条回落链是 ABI 分发的兼容基础：旧客户端不传 [abi]，
  ///   只要清单里保留了泛化键就照常能收到更新。
  /// - [currentAssetBuild] 是本地已应用的资源包构建号；0 表示从未应用过。
  /// - [ignoredVersion] 是用户点过「跳过此版本」的版本号。
  /// - [notificationsDisabled] 是用户在设置里彻底关掉了「大版本更新提醒」。
  ///
  /// **返回值语义**：`notificationsDisabled` / `ignoredVersion` 只会把
  /// `optional` 降级为 `available`（设置页仍能看到），不会让更新消失，
  /// 也不会影响 `forced` 与 `assetsOnly`。
  static AppUpdateDecision decide({
    required AppUpdateManifest? manifest,
    required String currentVersion,
    required String platform,
    String? abi,
    int currentAssetBuild = 0,
    String? ignoredVersion,
    bool notificationsDisabled = false,
  }) {
    if (manifest == null) {
      return const AppUpdateDecision(
        kind: AppUpdateKind.none,
        reason: '未获取到更新清单，静默跳过',
      );
    }

    final assets = _resolveAssets(manifest.assets, currentAssetBuild);
    final release = manifest.release;

    // 1) 强制更新最优先，且不受「跳过」「关闭提醒」影响。
    final minSupported = manifest.minSupported;
    if (minSupported != null &&
        VersionUtils.isNewer(minSupported, currentVersion)) {
      return AppUpdateDecision(
        kind: AppUpdateKind.forced,
        release: release,
        assets: assets,
        effectiveLevel: release?.levelAgainst(currentVersion),
        reason: '当前版本 $currentVersion 低于最低支持版本 $minSupported',
      );
    }

    // 2) 整包更新。
    if (release != null && VersionUtils.isNewer(release.version, currentVersion)) {
      // 用与取产物相同的解析逻辑判断「有没有包」，避免两处判据不一致：
      // 若这里只查 downloads[platform]，清单写成 android-arm64 时会被误判为无产物。
      if (release.resolveTarget(platform, abi: abi) == null) {
        return AppUpdateDecision(
          kind: assets != null ? AppUpdateKind.assetsOnly : AppUpdateKind.none,
          assets: assets,
          reason: '清单未提供 $platform 平台的下载产物'
              '${abi == null ? '' : '（含 $abi 细分）'}，'
              '可用键：${release.availablePlatformKeys.join(', ')}',
        );
      }

      final level = release.levelAgainst(currentVersion);
      // 只要有整包更新就主动提示一次：自签小圈子分发没有应用商店，用户无法
      // 靠商店看到更新，静默（available）等于更新不存在。是否打扰改由两个
      // 用户可控开关决定——「跳过此版本」与「关闭更新提醒」，命中则降级为
      // 设置页可见但不弹窗，更新本身不会消失。
      final wantsPrompt = true;
      final suppressed =
          notificationsDisabled ||
          (ignoredVersion != null && ignoredVersion == release.version);

      if (wantsPrompt && !suppressed) {
        return AppUpdateDecision(
          kind: AppUpdateKind.optional,
          release: release,
          assets: assets,
          effectiveLevel: level,
          reason: '发现新版本 ${release.version}（${level.name}），提示用户',
        );
      }

      return AppUpdateDecision(
        kind: AppUpdateKind.available,
        release: release,
        assets: assets,
        effectiveLevel: level,
        reason: suppressed
            ? '更新 ${release.version} 已被用户忽略，降级为设置页提示'
            : '更新 ${release.version} 未弹窗（状态异常）',
      );
    }

    // 3) 只有资源热更新。
    if (assets != null) {
      return AppUpdateDecision(
        kind: AppUpdateKind.assetsOnly,
        assets: assets,
        reason: '资源热更新 build=${assets.build}',
      );
    }

    return AppUpdateDecision.none;
  }

  /// 资源包是否需要更新：构建号必须严格大于本地已应用的。
  static AssetUpdatePackage? _resolveAssets(
    AssetUpdatePackage? assets,
    int currentBuild,
  ) {
    if (assets == null) return null;
    if (assets.build <= currentBuild) return null;
    return assets;
  }
}
