/// App 更新流程里的可预期失败。
///
/// 与游戏模块的 `GameException` 同构：用来区分「业务上可预期的失败」
/// （网络不通、清单是坏 JSON、校验不通过）和「真的写错了」。
class AppUpdateException implements Exception {
  /// 面向用户/日志的错误描述。
  final String message;

  const AppUpdateException(this.message);

  @override
  String toString() => 'AppUpdateException: $message';
}
