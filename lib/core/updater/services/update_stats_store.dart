import 'package:shared_preferences/shared_preferences.dart';

/// 更新结果的类别。
///
/// `app*` 指整包 APK 更新（用户点击「立即更新」发起），
/// `asset*` 指静默资源热更。统计只覆盖**本机实际发起过下载**的动作，
/// 因此「打开下载页」（非 Android 平台）不计数。
enum UpdateOutcome {
  appSuccess,
  appFailure,
  appCancelled,
  assetSuccess,
  assetFailure,
}

/// 更新下载结果的累计统计（纯数据）。
class UpdateStats {
  final int appSuccess;
  final int appFailure;
  final int appCancelled;
  final int assetSuccess;
  final int assetFailure;

  /// 最近一次结果发生的时间与类别；从未记录过时为 null。
  final DateTime? lastAt;
  final UpdateOutcome? lastOutcome;

  const UpdateStats({
    this.appSuccess = 0,
    this.appFailure = 0,
    this.appCancelled = 0,
    this.assetSuccess = 0,
    this.assetFailure = 0,
    this.lastAt,
    this.lastOutcome,
  });

  static const UpdateStats empty = UpdateStats();
}

/// 更新结果的本地计数（SharedPreferences）。
///
/// 用途：小圈子自签分发没有服务端上报，链路到底稳不稳只能看本机计数。
/// 数据只在「版本更新」页展示给用户自己，并提供一键清零，不上报、不追踪。
class UpdateStatsStore {
  const UpdateStatsStore();

  static const String _kAppSuccess = 'update_stats_app_success';
  static const String _kAppFailure = 'update_stats_app_failure';
  static const String _kAppCancelled = 'update_stats_app_cancelled';
  static const String _kAssetSuccess = 'update_stats_asset_success';
  static const String _kAssetFailure = 'update_stats_asset_failure';
  static const String _kLastAt = 'update_stats_last_at';
  static const String _kLastOutcome = 'update_stats_last_outcome';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<UpdateStats> read() async {
    final prefs = await _prefs();
    final millis = prefs.getInt(_kLastAt);
    final outcomeName = prefs.getString(_kLastOutcome);
    UpdateOutcome? outcome;
    if (outcomeName != null) {
      for (final value in UpdateOutcome.values) {
        if (value.name == outcomeName) {
          outcome = value;
          break;
        }
      }
    }
    return UpdateStats(
      appSuccess: prefs.getInt(_kAppSuccess) ?? 0,
      appFailure: prefs.getInt(_kAppFailure) ?? 0,
      appCancelled: prefs.getInt(_kAppCancelled) ?? 0,
      assetSuccess: prefs.getInt(_kAssetSuccess) ?? 0,
      assetFailure: prefs.getInt(_kAssetFailure) ?? 0,
      lastAt: (millis == null || millis <= 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
      lastOutcome: outcome,
    );
  }

  /// 记录一次结果，对应计数 +1 并刷新「最近一次」，返回更新后的统计。
  Future<UpdateStats> record(UpdateOutcome outcome) async {
    final prefs = await _prefs();
    final key = switch (outcome) {
      UpdateOutcome.appSuccess => _kAppSuccess,
      UpdateOutcome.appFailure => _kAppFailure,
      UpdateOutcome.appCancelled => _kAppCancelled,
      UpdateOutcome.assetSuccess => _kAssetSuccess,
      UpdateOutcome.assetFailure => _kAssetFailure,
    };
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
    await prefs.setInt(
      _kLastAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(_kLastOutcome, outcome.name);
    return read();
  }

  /// 清空全部计数。
  Future<UpdateStats> reset() async {
    final prefs = await _prefs();
    await Future.wait([
      prefs.remove(_kAppSuccess),
      prefs.remove(_kAppFailure),
      prefs.remove(_kAppCancelled),
      prefs.remove(_kAssetSuccess),
      prefs.remove(_kAssetFailure),
      prefs.remove(_kLastAt),
      prefs.remove(_kLastOutcome),
    ]);
    return UpdateStats.empty;
  }
}
