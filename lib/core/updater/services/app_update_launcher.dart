import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/download_mirrors.dart';
import '../../services/file_downloader.dart';
import '../../services/multi_source_downloader.dart';
import '../../utils/app_logger.dart';
import '../models/app_update_manifest.dart';
import 'app_update_exception.dart';

/// 一次「应用更新」动作的结果。
enum AppUpdateLaunchResult {
  /// 已下载完成并拉起系统安装器（Android 自签场景）。
  installStarted,

  /// 已交给浏览器 / 应用商店打下载页（iOS、桌面，或清单只给了网页地址）。
  openedDownloadPage,

  /// 失败。
  failed,
}

/// 把「更新」真正落地：下载安装包并交给系统去装，或打开下载页。
///
/// 平台差异是硬约束，这里明确区分：
/// - **Android**：可以下载 APK 并拉起系统安装器（自签分发场景）。首次系统会要求
///   用户手动允许「安装未知应用」，这是系统行为，App 无法代劳。
/// - **iOS**：**不能**自行下载安装，只能打开 App Store / 下载页。
/// - **桌面**：没有统一安装器，交给浏览器下载。
///
/// Android 下载走**多源回退**：清单镜像 → 内置公益加速镜像 → GitHub 直链，
/// 任一源失败（网络错误、sha256 不符、大小不符）就删掉残缺包换下一个，
/// 全部失败才报错。详见 [DownloadMirrors]。
class AppUpdateLauncher {
  const AppUpdateLauncher({
    Future<Directory> Function()? tempDirProvider,
  }) : _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  final Future<Directory> Function() _tempDirProvider;

  static const String _apkMimeType = 'application/vnd.android.package-archive';

  /// 是否应该走「应用内下载 + 调系统安装器」。
  ///
  /// 只有 Android 且产物确实是 APK 时才敢这么做：把非 APK 交给安装器只会报错。
  bool shouldInstallInApp(AppDownloadTarget target) {
    if (kIsWeb) return false;
    if (!Platform.isAndroid) return false;
    final path = target.url.toLowerCase().split('?').first;
    return path.endsWith('.apk');
  }

  /// 应用更新。[onProgress] 仅在走应用内下载时回调（0~1，换源后从 0 重新计）。
  ///
  /// [isCancelled] 在应用内下载期间被轮询，返回 true 时立即中止（不重试、
  /// 不换源）并抛出「下载已取消」；跳下载页路径不受影响。
  Future<AppUpdateLaunchResult> apply(
    AppDownloadTarget target, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final uri = Uri.tryParse(target.url);
    if (uri == null) {
      throw const AppUpdateException('更新地址不合法');
    }

    if (!shouldInstallInApp(target)) {
      final opened = await openDownloadPage(uri);
      return opened
          ? AppUpdateLaunchResult.openedDownloadPage
          : AppUpdateLaunchResult.failed;
    }
    return _downloadAndInstall(
      target,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// 用外部浏览器 / 应用商店打开地址。
  Future<bool> openDownloadPage(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error, stack) {
      AppLogger.warn('AppUpdateLauncher', '打开下载页失败: $uri', error, stack);
      return false;
    }
  }

  Future<AppUpdateLaunchResult> _downloadAndInstall(
    AppDownloadTarget target, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final candidates = DownloadMirrors.expand(
      target.url,
      explicitMirrors: target.mirrors,
    );
    final dir = await _tempDirProvider();

    final String apkPath;
    try {
      apkPath = await MultiSourceDownloader.downloadVerified(
        candidates: candidates,
        destDir: dir,
        filePrefix: 'update',
        expectedSha256: target.sha256,
        expectedSize: target.sizeBytes,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } on FileDownloadException catch (error) {
      final msg = _userFriendlyMessage(error.message);
      throw AppUpdateException(msg);
    }

    try {
      final result = await OpenFilex.open(apkPath, type: _apkMimeType);
      if (result.type == ResultType.done) {
        // 安装器已经接手，此时不能删 APK——它还在读这个文件。
        return AppUpdateLaunchResult.installStarted;
      }
      throw AppUpdateException(
        '无法拉起安装器：${result.message}。'
        '若是首次安装，请在系统设置里允许本应用「安装未知应用」。',
      );
    } catch (error) {
      await _deleteQuietly(apkPath);
      rethrow;
    }
  }

  /// 清理历次更新遗留在缓存目录里的安装包 / 资源包。
  ///
  /// 成功拉起系统安装器后**不能**立刻删 APK（安装器还在读这个文件），
  /// 而事后没有任何清理点，于是每成功更新一次就永久留一份 20~60MB 的残包。
  /// 只在启动时清理**超过 [olderThan] 的旧包**：正在下载、或用户刚拿到
  /// 安装弹窗还没点的那份不会被误删。
  ///
  /// 文件名里带我们写入的毫秒时间戳（`update-<ms>-0.apk` / `asset-<ms>.zip`
  /// / `asset-stage-<ms>`），解析不出时间戳的一律跳过——同一个缓存目录里
  /// 还可能有别的模块写入的文件，宁可漏清也不能误删。
  static Future<void> cleanupStaleFiles({
    Future<Directory> Function() tempDirProvider = getTemporaryDirectory,
    Duration olderThan = const Duration(hours: 6),
  }) async {
    try {
      final dir = await tempDirProvider();
      if (!await dir.exists()) return;
      final cutoffMs =
          DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        if (!_isOwnedTempName(name)) continue;
        final stamp = _stampOf(name);
        if (stamp == null || stamp > cutoffMs) continue;
        try {
          await entity.delete(recursive: true);
        } catch (error) {
          AppLogger.warn(
            'AppUpdateLauncher',
            '清理过期更新临时文件失败: $name',
            error,
          );
        }
      }
    } catch (error, stack) {
      AppLogger.warn('AppUpdateLauncher', '清理更新临时文件失败', error, stack);
    }
  }

  /// 是否本模块写进缓存目录的文件（前缀由本模块自己约定）。
  static bool _isOwnedTempName(String name) =>
      name.startsWith('update-') || name.startsWith('asset-');

  /// 取文件名里第一个 13 位毫秒时间戳；取不到返回 null。
  static int? _stampOf(String name) {
    final match = RegExp(r'\d{13}').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// 把底层网络/校验异常翻译成用户能看懂的话。
  static String _userFriendlyMessage(String raw) {
    if (raw.contains('Connection closed') ||
        raw.contains('Connection reset') ||
        raw.contains('Connection refused')) {
      return '下载到一半网络断了，所有备用线路都试过了，请检查网络后重试';
    }
    if (raw.contains('TimeoutException') || raw.contains('timed out')) {
      return '下载太慢自动超时了，请换个网络环境再试';
    }
    if (raw.contains('sha256')) {
      return '下载内容不完整（校验失败），请重试';
    }
    if (raw.contains('大小不符')) {
      return '下载到一半中断了，文件不完整，请重试';
    }
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup')) {
      return '连不上下载服务器，请检查网络或稍后重试';
    }
    return '下载失败，请稍后重试（$raw）';
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      AppLogger.warn('AppUpdateLauncher', '清理安装包失败: $path', error);
    }
  }
}
