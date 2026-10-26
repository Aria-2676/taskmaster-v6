import '../../utils/version_utils.dart';
import 'app_update_manifest.dart';

/// 版本检查的结论类别。
///
/// 打扰策略：自签小圈子分发没有应用商店兜底，**只要有整包更新就主动提示一次**；
/// 用户可用「稍后」「跳过此版本」或设置开关收敛打扰，命中抑制时降级为
/// [available]（设置页可见但不弹窗），更新不会消失；低于最低支持版本时强制。
enum AppUpdateKind {
  /// 没有可用更新。
  none,

  /// 只有资源热更新：后台静默下载，完全不打扰。
  assetsOnly,

  /// 有整包更新但不弹窗：只在设置页显示红点/入口。
  available,

  /// 有整包更新且值得弹窗：用户可「稍后」或「跳过此版本」。
  optional,

  /// 强制更新：当前版本低于最低支持版本，不可关闭。
  forced,
}

/// 一次版本检查的完整结论。
class AppUpdateDecision {
  /// 结论类别。
  final AppUpdateKind kind;

  /// 可用的整包版本；[AppUpdateKind.assetsOnly] / [AppUpdateKind.none] 时为 null。
  final AppRelease? release;

  /// 可用的资源热更新包；没有时为 null。
  final AssetUpdatePackage? assets;

  /// 相对当前版本的变更级别；没有整包更新时为 null。
  final VersionChangeLevel? effectiveLevel;

  /// 人类可读的判定原因，用于日志与排查。
  final String reason;

  const AppUpdateDecision({
    required this.kind,
    this.release,
    this.assets,
    this.effectiveLevel,
    this.reason = '',
  });

  /// 「无更新」的快捷常量。
  static const AppUpdateDecision none = AppUpdateDecision(
    kind: AppUpdateKind.none,
    reason: '已是最新版本',
  );

  /// 是否存在任何可获取的更新（整包或资源）。
  bool get hasUpdate => kind != AppUpdateKind.none;

  /// 是否有整包更新可用。
  bool get hasRelease => release != null;

  /// 是否有资源热更新可用。
  bool get hasAssets => assets != null;

  /// 是否应该主动弹窗打扰用户。
  bool get shouldPrompt =>
      kind == AppUpdateKind.optional || kind == AppUpdateKind.forced;

  /// 用户能否关闭这次提示。
  ///
  /// 强制更新不允许关闭——它存在的意义就是不让用户停留在不兼容的旧版本上。
  bool get canDismiss => kind != AppUpdateKind.forced;

  @override
  String toString() =>
      'AppUpdateDecision(kind: ${kind.name}, '
      'release: ${release?.version}, '
      'assetsBuild: ${assets?.build}, reason: $reason)';
}
