import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/v6_plugin_tables.dart';
import '../services/file_downloader.dart';
import '../services/zip_extractor.dart';
import 'plugin_index.dart';
import 'plugin_manifest.dart';
import 'plugin_store.dart';

/// 安装失败。**所有失败路径都归到这一种异常**，调用方不必区分是网络、
/// 校验还是格式问题 —— 对用户来说都是"装不上"。
class PluginInstallException implements Exception {
  const PluginInstallException(this.message);

  final String message;

  @override
  String toString() => 'PluginInstallException: $message';
}

/// 下载器。抽成函数类型是为了测试能塞本地文件，不必起 HTTP 服务。
typedef PluginPackageFetcher = Future<void> Function({
  required Uri url,
  required String destPath,
  void Function(int received, int? total)? onProgress,
});

/// 安装 / 卸载 / 启动自愈。
///
/// 目录约定：
/// ```
/// <root>/<id>/<version>/...      已安装
/// <root>/.tmp/<id>_<version>/    下载与解压的工作区，失败即清
/// ```
class PluginInstaller {
  PluginInstaller({
    required Database db,
    required Directory rootDir,
    PluginSchemaRegistry? schemas,
    PluginPackageFetcher? fetch,
  })  : _db = db,
        _rootDir = rootDir,
        _schemas = schemas ?? PluginSchemaRegistry.instance,
        _fetch = fetch ?? _httpFetch,
        _store = PluginStore(db);

  final Database _db;
  final Directory _rootDir;
  final PluginSchemaRegistry _schemas;
  final PluginPackageFetcher _fetch;
  final PluginStore _store;

  PluginStore get store => _store;
  Directory get rootDir => _rootDir;

  /// 宿主库。启动插件时要用它构造 `TaskRepository` ——
  /// 从这里取，是为了让"安装器"成为插件运行环境的**唯一入口**，
  /// 调用方不必另外持有一个 Database 引用（那份引用很容易在热重载后变成 null）。
  Database get db => _db;

  static Future<void> _httpFetch({
    required Uri url,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) =>
      FileDownloader.download(url: url, destPath: destPath, onProgress: onProgress);

  /// 下载 → 校验 → 解压 → 读清单 → 原子落位 → 登记。
  ///
  /// 任何一步失败都只会留下 `.tmp` 里的残留（[finally] 会清），
  /// **不会出现"登记了但文件不全"的中间态**。
  Future<InstalledPlugin> install(
    PluginIndexEntry entry, {
    required Uri packageUrl,
    void Function(double progress)? onProgress,
  }) async {
    if (!entry.installable) {
      throw PluginInstallException(
        '契约版本 ${entry.contract} 不受支持（宿主支持 ${PluginContract.min}~${PluginContract.current}）',
      );
    }

    final workDir = Directory(p.join(_rootDir.path, '.tmp', '${entry.id}_${entry.version}'));
    await _deleteQuietly(workDir);
    await workDir.create(recursive: true);

    try {
      final zipPath = p.join(workDir.path, 'package.zip');
      await _fetch(
        url: packageUrl,
        destPath: zipPath,
        onProgress: onProgress == null
            ? null
            : (received, total) {
                if (total != null && total > 0) onProgress(received / total);
              },
      );

      if (!await FileDownloader.verifySha256(zipPath, entry.package.sha256)) {
        throw const PluginInstallException('sha256 校验失败：包被替换或下载不完整');
      }

      final unpacked = Directory(p.join(workDir.path, 'unpacked'));
      await ZipExtractor.extract(zipPath: zipPath, targetDir: unpacked.path);

      final manifest = await _readManifest(unpacked);
      // 索引说什么就该装什么。不一致时以"拒绝"为准 ——
      // 否则升级检测（比较 version）会永远判断错误。
      if (manifest.id != entry.id) {
        throw PluginInstallException('包内 id（${manifest.id}）与索引（${entry.id}）不一致');
      }
      if (manifest.version != entry.version) {
        throw PluginInstallException(
          '包内版本（${manifest.version}）与索引（${entry.version}）不一致',
        );
      }

      final target = Directory(p.join(_rootDir.path, manifest.id, manifest.version));
      await _deleteQuietly(target);
      await target.parent.create(recursive: true);
      // rename 是同一分区内的原子操作：要么整目录到位，要么什么都没有
      await unpacked.rename(target.path);

      final installed = InstalledPlugin(
        pluginId: manifest.id,
        version: manifest.version,
        contract: manifest.contract,
        installDir: '${manifest.id}/${manifest.version}',
        installedAt: DateTime.now(),
      );
      await _store.upsert(installed);
      // 建表要在登记之后：表建失败了还能靠 reconcile 清掉登记，
      // 反过来会留下"表在、插件不在"的孤儿表。
      _schemas.registerStorage(manifest.id, manifest.storage);
      await _schemas.materialize(_db);
      await _removeOtherVersions(manifest.id, keep: manifest.version);
      return installed;
    } on PluginFormatException catch (error) {
      throw PluginInstallException('plugin.json 不合法：${error.message}');
    } on ZipExtractorException catch (error) {
      throw PluginInstallException('解压失败：${error.message}');
    } finally {
      await _deleteQuietly(workDir);
      await _deleteQuietly(Directory(p.join(_rootDir.path, '.tmp')));
    }
  }

  /// 卸载顺序：**先删插件表 → 再删文件 → 最后删登记**。
  ///
  /// 反过来会在中途失败时留下"登记说有、文件没有"，插件出现在列表里却打不开。
  /// 现在这个顺序最坏也只会留下孤儿目录，下次 [reconcile] 会扫掉。
  Future<void> uninstall(String pluginId) async {
    final installed = await _store.find(pluginId);
    if (installed == null) return;

    await _schemas.dropPlugin(_db, pluginId);
    await _deleteQuietly(Directory(p.join(_rootDir.path, pluginId)));
    await _store.remove(pluginId);
  }

  /// 启动时按已装清单把插件表补齐。
  ///
  /// 为什么需要它：`PluginSchemaRegistry` 是**内存**注册表，
  /// 每次冷启动都是空的。不补这一步，重启后插件的表就"不存在"了 ——
  /// 表现是插件一打开就报"没有声明过这张表"。
  ///
  /// 读不出 manifest 的插件直接跳过（包坏了由 [reconcile] 处理），
  /// 一个坏包不该挡住其他插件的表。
  Future<void> ensureSchemas() async {
    for (final item in await _store.all()) {
      try {
        final manifest = await manifestOf(item);
        _schemas.registerStorage(item.pluginId, manifest.storage);
      } catch (_) {
        continue;
      }
    }
    await _schemas.materialize(_db);
  }

  /// 启动时自愈：登记了但目录没了 → 删登记；目录在但没登记 → 删目录。
  Future<PluginReconcileReport> reconcile() async {
    final report = PluginReconcileReport();

    for (final item in await _store.all()) {
      final dir = Directory(p.join(_rootDir.path, item.installDir));
      if (!await dir.exists()) {
        await _store.remove(item.pluginId);
        report.removedRecords.add(item.pluginId);
      }
    }

    final known = (await _store.all()).map((e) => e.pluginId).toSet();
    if (await _rootDir.exists()) {
      await for (final entity in _rootDir.list()) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (name == '.tmp') continue;
        if (!known.contains(name)) {
          await _deleteQuietly(entity);
          report.removedDirs.add(name);
        }
      }
    }
    return report;
  }

  /// 入口 HTML 的绝对路径（给 WebView 用）。
  ///
  /// 入口文件名来自包内 `plugin.json`，不是硬编码的 `index.html` ——
  /// 清单允许放在子目录里（`pages/index.html`）。
  Future<String> entryFileOf(InstalledPlugin plugin) async =>
      p.join(await directoryOf(plugin), (await manifestOf(plugin)).entry);

  /// 插件安装目录（绝对路径）
  Future<String> directoryOf(InstalledPlugin plugin) async {
    final dir = Directory(p.join(_rootDir.path, plugin.installDir));
    if (!await dir.exists()) {
      throw PluginInstallException('插件目录不存在：${plugin.installDir}');
    }
    return dir.path;
  }

  /// 读包内的 `plugin.json`。桥接层要用它的权限声明。
  Future<PluginManifest> manifestOf(InstalledPlugin plugin) async =>
      _readManifest(Directory(await directoryOf(plugin)));

  Future<PluginManifest> _readManifest(Directory dir) async {
    final file = File(p.join(dir.path, 'plugin.json'));
    if (!await file.exists()) {
      throw const PluginInstallException('包里没有 plugin.json');
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const PluginInstallException('plugin.json 顶层必须是对象');
    }
    return PluginManifest.parse(Map<String, Object?>.from(decoded));
  }

  Future<void> _removeOtherVersions(String pluginId, {required String keep}) async {
    final dir = Directory(p.join(_rootDir.path, pluginId));
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is Directory && p.basename(entity.path) != keep) {
        await _deleteQuietly(entity);
      }
    }
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不该让安装/卸载失败 —— 下次 reconcile 会再扫一遍
    }
  }
}

/// [PluginInstaller.reconcile] 的结果，用于启动时打日志。
class PluginReconcileReport {
  final List<String> removedRecords = <String>[];
  final List<String> removedDirs = <String>[];

  bool get isClean => removedRecords.isEmpty && removedDirs.isEmpty;

  @override
  String toString() =>
      'PluginReconcileReport(removedRecords=$removedRecords, removedDirs=$removedDirs)';
}
