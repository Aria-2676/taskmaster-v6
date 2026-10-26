import 'package:flutter/foundation.dart';

/// 统一日志入口。
///
/// 主要用途是替代散落的 `catch (_) {}`：异常至少要留下可观测的痕迹，
/// 否则真实的数据库/文件/同步故障会被静默吞掉，线上只能看到「功能没反应」。
/// 仅在 debug 模式输出，release 构建下不产生任何开销。
class AppLogger {
  const AppLogger._();

  /// 记录非致命异常：已做降级处理，但需要可见以便排查。
  static void warn(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (!kDebugMode) return;
    debugPrint('[WARN][$tag] $message${error == null ? '' : ' | $error'}');
    if (stackTrace != null) {
      debugPrint('[WARN][$tag] $stackTrace');
    }
  }

  /// 记录预期外的失败。
  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (!kDebugMode) return;
    debugPrint('[ERROR][$tag] $message${error == null ? '' : ' | $error'}');
    if (stackTrace != null) {
      debugPrint('[ERROR][$tag] $stackTrace');
    }
  }
}
