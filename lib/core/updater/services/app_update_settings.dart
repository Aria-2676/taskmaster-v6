import 'package:shared_preferences/shared_preferences.dart';

/// 更新功能的本地状态。
///
/// 版本检查是「用户可关掉」的功能，因此这几个状态必须落盘：
/// 跳过过哪个版本、是否关掉了提醒、上次检查时间、本地已应用的资源包构建号。
class AppUpdateSettings {
  const AppUpdateSettings({this.scope = ''});

  /// 键前缀，用来把不同渠道的更新状态**隔开**。
  ///
  /// 为什么必须隔开：V5 与 V6 是同包名，共用一份 SharedPreferences。
  /// 其中最硬的一条是资源包构建号 —— V5 应用过 `build 5`，V6 读到会以为
  /// 自己也应用过，于是静默跳过 V6 的资源更新，而且**永远不会自愈**。
  ///
  /// 空字符串 = V5 原有的键名，一个字符都不变（已发布的包不能改）。
  final String scope;

  String _key(String name) =>
      scope.isEmpty ? 'app_update_$name' : 'app_update_${scope}_$name';

  String get _kIgnoredVersion => _key('ignored_version');
  String get _kNotificationsEnabled => _key('notifications_enabled');
  String get _kWifiOnlyAutoDownload => _key('wifi_only_auto');
  String get _kLastCheckAt => _key('last_check_at');
  String get _kAssetBuild => _key('asset_build');
  String get _kBgVersion => _key('env_version');
  String get _kBgPlatform => _key('env_platform');
  String get _kBgAbi => _key('env_abi');
  String get _kLastNotifiedVersion => _key('last_notified_version');

  /// 自动检查的最小间隔；手动「检查更新」不受此限制。
  ///
  /// 1 小时：清单只有几 KB，且有多源回退，请求成本可忽略；短间隔能让新版本
  /// 在「下次打开/回前台」时基本必被发现（真正的后台唤醒由 WorkManager
  /// 周期任务负责）。
  static const Duration autoCheckInterval = Duration(hours: 1);

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  /// 用户点过「跳过此版本」的版本号；没有则为 null。
  Future<String?> ignoredVersion() async {
    final prefs = await _prefs();
    final value = prefs.getString(_kIgnoredVersion);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 记下「用户跳过了这个版本」。
  ///
  /// 只跳过指定版本：下一个版本仍然会提醒，避免用户被永久静音后错过重要更新。
  Future<void> setIgnoredVersion(String version) async {
    final prefs = await _prefs();
    await prefs.setString(_kIgnoredVersion, version);
  }

  /// 清除跳过记录（用户手动检查更新时可不再受它影响）。
  Future<void> clearIgnoredVersion() async {
    final prefs = await _prefs();
    await prefs.remove(_kIgnoredVersion);
  }

  /// 是否允许「大版本更新」弹窗提醒。默认开启。
  Future<bool> notificationsEnabled() async {
    final prefs = await _prefs();
    return prefs.getBool(_kNotificationsEnabled) ?? true;
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs = await _prefs();
    await prefs.setBool(_kNotificationsEnabled, enabled);
  }

  /// 是否「仅 WiFi 下才自动下载资源更新包」。默认开启。
  ///
  /// 只管**无人值守的静默资源热更**：整包更新永远由用户点击「立即更新」
  /// 发起，不受此开关限制；用户主动点的下载哪怕在蜂窝网络也照常进行。
  Future<bool> wifiOnlyAutoDownload() async {
    final prefs = await _prefs();
    return prefs.getBool(_kWifiOnlyAutoDownload) ?? true;
  }

  Future<void> setWifiOnlyAutoDownload(bool enabled) async {
    final prefs = await _prefs();
    await prefs.setBool(_kWifiOnlyAutoDownload, enabled);
  }

  /// 上次检查更新的时间；从未检查过时为 null。
  Future<DateTime?> lastCheckAt() async {
    final prefs = await _prefs();
    final millis = prefs.getInt(_kLastCheckAt);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> markChecked([DateTime? at]) async {
    final prefs = await _prefs();
    await prefs.setInt(
      _kLastCheckAt,
      (at ?? DateTime.now()).millisecondsSinceEpoch,
    );
  }

  /// 距离上次检查是否已经超过 [interval]，可以自动再查一次。
  Future<bool> isAutoCheckDue({
    Duration interval = autoCheckInterval,
    DateTime? now,
  }) async {
    final last = await lastCheckAt();
    if (last == null) return true;
    return (now ?? DateTime.now()).difference(last) >= interval;
  }

  /// 本地已应用的资源热更新包构建号；0 表示从未应用过。
  Future<int> assetBuild() async {
    final prefs = await _prefs();
    return prefs.getInt(_kAssetBuild) ?? 0;
  }

  Future<void> setAssetBuild(int build) async {
    final prefs = await _prefs();
    await prefs.setInt(_kAssetBuild, build);
  }

  /// 把「本机环境」快照落盘，供后台 WorkManager 任务读取。
  ///
  /// 后台 isolate 里不宜跑 package_info / getprop（插件注册与进程调用都不稳），
  /// 主 App 每次刷新环境时顺手存一份，后台只读 SharedPreferences 即可。
  Future<void> saveEnvironmentSnapshot({
    required String version,
    required String platform,
    String? abi,
  }) async {
    final prefs = await _prefs();
    await prefs.setString(_kBgVersion, version);
    await prefs.setString(_kBgPlatform, platform);
    if (abi != null) {
      await prefs.setString(_kBgAbi, abi);
    } else {
      await prefs.remove(_kBgAbi);
    }
  }

  Future<({String version, String platform, String? abi})>
  readEnvironmentSnapshot() async {
    final prefs = await _prefs();
    return (
      version: prefs.getString(_kBgVersion) ?? '',
      platform: prefs.getString(_kBgPlatform) ?? 'android',
      abi: prefs.getString(_kBgAbi),
    );
  }

  /// 后台已经发过通知的版本号；用于「同一版本只通知一次」。
  Future<String?> lastNotifiedVersion() async {
    final prefs = await _prefs();
    final value = prefs.getString(_kLastNotifiedVersion);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setLastNotifiedVersion(String version) async {
    final prefs = await _prefs();
    await prefs.setString(_kLastNotifiedVersion, version);
  }
}
