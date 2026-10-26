import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 通用 zip 解压（游戏包与资源热更新包共用）。
///
/// 全部为静态无状态方法，便于在 [Isolate] 中执行重计算，也便于单元测试直接调用。
///
/// 安全策略是 **fail-closed**：条目出现绝对路径、`..` 或符号链接时**整包拒绝**，
/// 而不是跳过该条目——否则畸形包会产出「装了一半」的目录且难以察觉，
/// 比直接失败更糟。压缩包来自外网，这个判断必须在写入任何文件之前完成。
class ZipExtractor {
  const ZipExtractor._();

  /// 解压 [zipPath] 到 [targetDir]。
  ///
  /// 失败时抛出 [ZipExtractorException]。**不保证 targetDir 无残留**：
  /// 调用方若需要原子性，应先解压到临时目录再整体替换。
  static Future<void> extract({
    required String zipPath,
    required String targetDir,
  }) async {
    final root = Directory(targetDir).absolute.path;
    await Directory(root).create(recursive: true);

    final input = InputFileStream(zipPath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (error) {
      await input.close();
      throw ZipExtractorException('压缩包解析失败：$error');
    }

    try {
      // `ZipDecoder().decodeStream` 对垃圾输入不抛错也不产出条目，会静默
      // 「成功」。这里显式判空，把畸形包转成错误而非产出空目录。
      if (archive.isEmpty) {
        throw const ZipExtractorException('压缩包为空或已损坏');
      }
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        _assertSafeEntry(name, entry);
        final destination = _resolveWithin(root, name);

        if (entry.isDirectory) {
          await Directory(destination).create(recursive: true);
          continue;
        }
        if (!entry.isFile) continue;

        await Directory(p.dirname(destination)).create(recursive: true);
        final output = OutputFileStream(destination);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
    } on ZipExtractorException {
      rethrow;
    } catch (error) {
      throw ZipExtractorException('压缩包解压失败：$error');
    } finally {
      archive.clearSync();
      await input.close();
    }
  }

  /// 统计目录总字节数（递归）。
  static Future<int> directorySize(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 文件可能在统计期间被删除，忽略。
        }
      }
    }
    return total;
  }

  /// 校验压缩包条目是否安全（防 zip-slip / 符号链接攻击）。
  static void _assertSafeEntry(String name, ArchiveFile entry) {
    if (entry.isSymbolicLink) {
      throw ZipExtractorException('压缩包包含符号链接：$name');
    }
    if (name.startsWith('/') || p.isAbsolute(name)) {
      throw ZipExtractorException('压缩包包含绝对路径：$name');
    }
    if (name.split('/').contains('..')) {
      throw ZipExtractorException('压缩包包含上级目录引用：$name');
    }
    _resolveWithin(Directory.systemTemp.path, name);
  }

  /// 将相对路径解析为 [root] 内的绝对路径；越界时抛出异常。
  static String _resolveWithin(String root, String relative) {
    final normalized = p.normalize(p.join(root, relative));
    final rel = p.relative(normalized, from: root);
    if (rel.startsWith('..') || p.isAbsolute(rel)) {
      throw ZipExtractorException('压缩包路径越界：$relative');
    }
    return normalized;
  }
}

/// 解压相关的错误。
///
/// 单独定义（而不是复用某个业务模块的异常）是为了让 `core` 不依赖 `modules`：
/// 各业务模块在自己的边界处把它转换成自己的异常类型，调用方的 catch 种类不受影响。
class ZipExtractorException implements Exception {
  /// 可直接展示给用户的错误说明。
  final String message;

  const ZipExtractorException(this.message);

  @override
  String toString() => 'ZipExtractorException: $message';
}
