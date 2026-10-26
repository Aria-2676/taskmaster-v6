import 'services/app_update_service.dart';
import 'services/app_update_settings.dart';

/// 更新渠道 = **一份清单 + 一套本地状态**。
///
/// 本仓库（V6）只有一条渠道：读仓库根目录的 `update.json`。
/// V5 那条线已经分出去了（`Aria-2676/note_study`），它的 `update.json`
/// 冻结在 6.0.0、永远不再改动 —— 两边的同名文件是**两个仓库里的两个文件**，
/// 不会互相影响。
///
/// 只换清单文件是不够的：本地状态也必须隔离，理由见
/// [AppUpdateSettings.scope] 的注释（资源包构建号串了会永久静默跳过热更）。
class UpdateChannel {
  const UpdateChannel({
    required this.manifestPath,
    required this.settingsScope,
  });

  /// 相对仓库根目录的清单文件名。
  final String manifestPath;

  /// 本地状态键前缀。
  final String settingsScope;

  /// 当前渠道。
  ///
  /// `settingsScope` 仍是 `v6`，**不是空的** —— 空串会落回 V5 时代的键名
  /// （`app_update_asset_build` 等），而用户从 V5 升级上来时那份 prefs
  /// 还在同一个应用目录里。串号的后果是 V6 以为自己也应用过那些资源包，
  /// 于是静默跳过 V6 的热更，而且永远不会自愈。
  static const UpdateChannel current = UpdateChannel(
    manifestPath: AppUpdateService.defaultManifestPath,
    settingsScope: 'v6',
  );

  /// 造一份读本渠道清单的 service。
  AppUpdateService createService() =>
      AppUpdateService(manifestPath: manifestPath);

  /// 本渠道专属的本地状态。
  AppUpdateSettings get settings => AppUpdateSettings(scope: settingsScope);

  @override
  String toString() => 'UpdateChannel($manifestPath)';
}
