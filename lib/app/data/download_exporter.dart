import 'package:flutter/services.dart';

/// 把备份文件存到系统的「下载/任务管家」。
///
/// 为什么不直接用 dart:io 写到 /storage/emulated/0/Download：
/// Android 10 以后 App 没有那个目录的写权限，硬写会失败。走 MediaStore 插入
/// 才是不需要任何权限的正路（原生侧在 `MainActivity.saveToDownloads`）。
///
/// 失败时**不吞错误**：把原生给的错误原文抛出去，页面上直接显示 ——
/// 这类问题（目录不可写、文件不存在）用户需要看到真实原因。
class DownloadExporter {
  const DownloadExporter();

  static const MethodChannel _channel = MethodChannel('taskmaster/export');

  /// 返回存好之后的路径（例如 `Download/任务管家/xxx.zip`）
  Future<String> saveToDownloads({required String path, required String name}) async {
    final saved = await _channel.invokeMethod<String>('saveToDownloads', <String, Object?>{
      'path': path,
      'name': name,
    });
    if (saved == null || saved.isEmpty) {
      throw StateError('系统没有返回保存位置');
    }
    return saved;
  }
}
