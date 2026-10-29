import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/backup/backup_service.dart';

/// 备份目录里的一个文件。列表页只读 `manifest.json`，不解全量。
class BackupFile {
  const BackupFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.manifest,
    required this.modifiedAt,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final BackupManifest manifest;
  final DateTime modifiedAt;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get timeLabel {
    final t = modifiedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 备份文件的落盘与枚举。
///
/// 目录放在 **App 专属外部目录**下（`/Android/data/<pkg>/files/backups`）：
/// 用户用文件管理器能找到，卸载 App 才会清掉，而且不需要任何存储权限。
/// 想放到用户自己选的位置（"下载"等）要走系统目录选择器（SAF），那是 S3。
class BackupRepository {
  BackupRepository({Directory? overrideDir}) : _overrideDir = overrideDir;

  /// 测试注入用：不碰真实设备目录
  final Directory? _overrideDir;

  /// 保留份数上限。超了**提示**不自动删 —— 备份是用户的退路，
  /// 自动删等于替他做决定。
  static const int keepLimit = 20;

  Future<Directory> directory() async {
    final base = _overrideDir ??
        Directory(
          p.join((await getExternalStorageDirectory())?.path ?? (await getApplicationDocumentsDirectory()).path, 'backups'),
        );
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  Future<List<BackupFile>> list() async {
    final dir = await directory();
    final files = <BackupFile>[];

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.${BackupFormat.fileExtension}')) continue;
      final manifest = _readManifest(await entity.readAsBytes());
      // 读不出 manifest 的文件（拷错了、损坏了）不列出来，但也不删
      if (manifest == null) continue;
      final stat = await entity.stat();
      files.add(BackupFile(
        path: entity.path,
        name: p.basename(entity.path),
        sizeBytes: stat.size,
        manifest: manifest,
        modifiedAt: stat.modified,
      ));
    }

    files.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return files;
  }

  /// 只解 `manifest.json`，为了列表页不必把几 MB 的 data.json 读出来
  BackupManifest? _readManifest(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final file = archive.files.firstWhere(
        (f) => f.name == BackupFormat.manifestEntry,
        orElse: () => ArchiveFile('missing', 0, <int>[]),
      );
      if (file.size == 0) return null;
      final text = utf8.decode(file.content as List<int>);
      return BackupManifest.fromJson(Map<String, Object?>.from(jsonDecode(text) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<BackupFile> save(Uint8List bytes, {required BackupManifest manifest, DateTime? now}) async {
    final dir = await directory();
    final stamp = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'taskmaster-v6-backup-'
        '${stamp.year}${two(stamp.month)}${two(stamp.day)}-'
        '${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}'
        '.${BackupFormat.fileExtension}';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return BackupFile(
      path: file.path,
      name: name,
      sizeBytes: bytes.length,
      manifest: manifest,
      modifiedAt: stamp,
    );
  }

  Future<void> delete(BackupFile file) async {
    final target = File(file.path);
    if (await target.exists()) await target.delete();
  }

  /// 超出保留上限的那些（列表页用来提示，不自动删）
  List<BackupFile> overLimit(List<BackupFile> files) {
    if (files.length <= keepLimit) return const <BackupFile>[];
    return files.sublist(keepLimit);
  }
}
