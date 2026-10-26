import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../utils/app_logger.dart';

/// 下载进度通知：在通知栏实时显示下载进度，用户切到后台也能看到。
///
/// 使用与后台更新检查相同的 channel（`app_update`），但用不同的通知 ID，
/// 避免覆盖「发现新版本」的通知。
class DownloadProgressNotification {
  DownloadProgressNotification._();

  static const String channelId = 'app_update';
  static const String channelName = '应用更新';
  static const int notificationId = 0x7606; // 比 BackgroundUpdateWorker 的 0x7605 大 1

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// 初始化通知插件（幂等）。
  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      _initialized = true;
    } catch (error, stack) {
      AppLogger.warn('DownloadProgressNotification', '初始化失败', error, stack);
    }
  }

  /// 显示或更新下载进度通知。
  ///
  /// [progress] 0.0 ~ 1.0，[version] 新版本号。
  static Future<void> showProgress(double progress, String version) async {
    await _ensureInitialized();
    final percent = (progress * 100).floor();
    await _plugin.show(
      notificationId,
      '正在下载新版本 $version',
      '已下载 $percent%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: '下载进度与更新提醒',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: percent,
          ongoing: true, // 下载中不可滑动关闭
          autoCancel: false,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  /// 下载完成，提示用户点击安装。
  static Future<void> showCompleted(String version) async {
    await _ensureInitialized();
    await _plugin.show(
      notificationId,
      '新版本 $version 下载完成',
      '点击开始安装',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: '下载进度与更新提醒',
          importance: Importance.high,
          priority: Priority.high,
          ongoing: false,
          autoCancel: true,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  /// 取消通知（下载失败或用户取消时）。
  static Future<void> cancel() async {
    try {
      await _plugin.cancel(notificationId);
    } catch (error, stack) {
      AppLogger.warn('DownloadProgressNotification', '取消通知失败', error, stack);
    }
  }
}
