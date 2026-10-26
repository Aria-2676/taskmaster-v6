import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../config/download_mirrors.dart';
import '../../services/file_downloader.dart';
import '../../services/multi_source_downloader.dart';
import '../../services/zip_extractor.dart';
import '../../utils/app_logger.dart';
import '../models/app_update_manifest.dart';
import 'app_update_exception.dart';
import 'hot_asset_store.dart';

/// 资源热更新包的落地。
///
/// 与「整包更新」不同，资源热更**不弹窗、不安装**，只把文件替换到本地，
/// 因此必须做到：要么完整替换成功，要么保持原样——**绝不能留下半旧半新的目录**。
/// 为此整个流程遵循三步：
///
/// 1. 下载到临时目录并校验 sha256（校验不过直接丢弃，不碰现有资源）；
/// 2. 解压到临时目录（解压失败也只污染临时目录）；
/// 3. 把现有目录改名为备份 → 把新目录改名为正式 → 删除备份。
///
/// 第 3 步里两次 rename 都发生在同一磁盘分区，是原子操作；即使中途崩溃，
/// 最坏情况是留下一个备份目录或一个待清理的临时目录，原有资源仍然可用。
class AppAssetApplier {
  const AppAssetApplier({this.rootDir, this.workDir});

  /// 资源落地的根目录；为 null 时默认用应用支持目录下的 `hot_assets`。
  final String? rootDir;

  /// 下载与解压的临时工作目录；为 null 时用系统临时目录。
  ///
  /// 单独开放注入有两个用处：测试可以指定沙箱目录；且能确保它与 [rootDir]
  /// 位于同一磁盘分区（重命名跨分区会失败，那样就只能退化成「先删后拷」，失去原子性）。
  final String? workDir;

  /// 当前资源目录的绝对路径。
  Future<String> resolveRoot() async {
    if (rootDir != null) return rootDir!;
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'hot_assets');
  }

  /// 临时工作目录。
  ///
  /// 优先用 path_provider 的系统临时目录；插件不可用时退回
  /// [Directory.systemTemp]——它只依赖 dart:io，不需要平台通道。
  ///
  /// 之所以要能降级：[workDir] 只是「放下载包和解压暂存」的地方，
  /// 它拿不到不该让整个热更失败；而 [rootDir] 是真正要落位的位置，
  /// 那种情况下失败必须暴露出来。
  Future<String> resolveWorkDir() async {
    if (workDir != null) return workDir!;
    try {
      return (await getTemporaryDirectory()).path;
    } catch (error, stack) {
      AppLogger.warn(
        'AppAssetApplier',
        'path_provider 取临时目录失败，改用 Directory.systemTemp',
        error,
        stack,
      );
      return Directory.systemTemp.path;
    }
  }

  /// 应用 [assets] 资源包，成功返回 true。
  ///
  /// 失败时抛出 [AppUpdateException]，且**保证现有资源不被破坏**。
  /// [onProgress] 回调下载进度（0~1）。
  Future<bool> apply(
    AssetUpdatePackage assets, {
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.tryParse(assets.url);
    if (uri == null) {
      throw const AppUpdateException('资源包地址不合法');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;

    // 路径解析也要纳入异常转换：resolveRoot / resolveWorkDir 会走
    // path_provider 的平台通道，绑定未初始化或插件不可用时抛的是
    // FlutterError / MissingPluginException，而不是本项目异常。
    // 若放在 try 之外，调用方会拿到一个它没打算 catch 的类型。
    final String targetRoot;
    final String workRoot;
    try {
      targetRoot = await resolveRoot();
      workRoot = await resolveWorkDir();
    } on AppUpdateException {
      rethrow;
    } catch (error, stack) {
      AppLogger.warn('AppAssetApplier', '资源目录解析失败', error, stack);
      throw AppUpdateException('无法确定资源目录：$error');
    }

    final stageDir = p.join(workRoot, 'asset-stage-$stamp');
    String? zipPath;

    try {
      // ① 多源下载：清单镜像 → 内置加速镜像 → 原始地址，单源内自动 Range
      // 续传与指数退避；下载完成即在下载器内做 sha256 / 大小校验，
      // 任一源不符就删残包换下一个，全部失败才抛异常。
      final candidates = DownloadMirrors.expand(
        assets.url,
        explicitMirrors: assets.mirrors,
      );
      zipPath = await MultiSourceDownloader.downloadVerified(
        candidates: candidates,
        destDir: Directory(workRoot),
        // 文件名前缀 `asset-` 与启动时的残留清理约定保持一致。
        filePrefix: 'asset',
        expectedSha256: assets.sha256,
        expectedSize: assets.sizeBytes,
        onProgress: onProgress,
      );

      // ② 解压到临时目录（脏数据只落在临时区）
      if (await Directory(stageDir).exists()) {
        await Directory(stageDir).delete(recursive: true);
      }
      await ZipExtractor.extract(zipPath: zipPath, targetDir: stageDir);

      await _promote(stageDir: stageDir, targetRoot: targetRoot, stamp: stamp);
      // 目录里的文件整批换过了，读取器缓存里的「不存在」结论已经失效；
      // 不清掉的话新素材要等下次冷启动才生效。
      HotAssetStore.instance.invalidate();
      return true;
    } on AppUpdateException {
      rethrow;
    } on FileDownloadException catch (error) {
      throw AppUpdateException(error.message);
    } on ZipExtractorException catch (error) {
      throw AppUpdateException(error.message);
    } catch (error, stack) {
      AppLogger.warn('AppAssetApplier', '资源热更新失败', error, stack);
      throw AppUpdateException('资源热更新失败：$error');
    } finally {
      if (zipPath != null) await _deleteQuietly(zipPath);
      await _deleteDirQuietly(stageDir);
    }
  }

  /// 把临时目录「晋升」为正式资源目录：备份旧目录 → 改名新目录 → 删备份。
  Future<void> _promote({
    required String stageDir,
    required String targetRoot,
    required int stamp,
  }) async {
    final backupDir = '$targetRoot.bak-$stamp';
    var hasBackup = false;

    if (await Directory(targetRoot).exists()) {
      await _deleteDirQuietly(backupDir);
      await Directory(targetRoot).rename(backupDir);
      hasBackup = true;
    }

    try {
      await Directory(p.dirname(targetRoot)).create(recursive: true);
      await Directory(stageDir).rename(targetRoot);
    } catch (error) {
      // 晋升失败：把备份改名回去，保证原有资源仍可用。
      if (hasBackup && !await Directory(targetRoot).exists()) {
        try {
          await Directory(backupDir).rename(targetRoot);
        } catch (restoreError, stack) {
          AppLogger.warn(
            'AppAssetApplier',
            '资源回滚失败，本地资源可能需要重新下载: $targetRoot',
            restoreError,
            stack,
          );
        }
      }
      throw AppUpdateException('资源替换失败：$error');
    }

    // 到这里新资源已就位，备份只是清理，失败不影响正确性。
    if (hasBackup) await _deleteDirQuietly(backupDir);
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      AppLogger.warn('AppAssetApplier', '清理文件失败: $path', error);
    }
  }

  Future<void> _deleteDirQuietly(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      AppLogger.warn('AppAssetApplier', '清理目录失败: $path', error);
    }
  }
}
