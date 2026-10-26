import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v5_app/core/services/network_info.dart';
import 'package:v5_app/core/updater/models/app_update_manifest.dart';
import 'package:v5_app/core/updater/providers/app_update_provider.dart';
import 'package:v5_app/core/updater/services/app_asset_applier.dart';
import 'package:v5_app/core/updater/services/app_update_exception.dart';
import 'package:v5_app/core/updater/services/app_update_launcher.dart';
import 'package:v5_app/core/updater/services/app_update_service.dart';

/// 可控网络闸门。
class _FakeNetworkInfo extends NetworkInfo {
  _FakeNetworkInfo(this._allow);
  bool _allow;
  set allow(bool value) => _allow = value;

  @override
  Future<bool> allowsUnmeteredDownload() async => _allow;
}

class _FakeService extends AppUpdateService {
  _FakeService(this.manifest);
  final AppUpdateManifest? manifest;

  @override
  Future<AppUpdateManifest?> tryFetchManifest() async => manifest;
}

class _FakeAssetApplier extends AppAssetApplier {
  int applyCount = 0;
  bool shouldThrow = false;
  int? lastBuild;

  @override
  Future<bool> apply(
    AssetUpdatePackage assets, {
    void Function(double progress)? onProgress,
  }) async {
    applyCount++;
    lastBuild = assets.build;
    if (shouldThrow) throw const AppUpdateException('模拟资源下载失败');
    return true;
  }
}

class _FakeLauncher extends AppUpdateLauncher {
  _FakeLauncher(this._behavior);
  final Future<AppUpdateLaunchResult> Function(bool Function()? isCancelled)
  _behavior;

  @override
  Future<AppUpdateLaunchResult> apply(
    AppDownloadTarget target, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) =>
      _behavior(isCancelled);
}

/// 通知平台接口假实现：必须 extends（PlatformInterface 禁止 implements，
/// 且 token 经父构造继承才能通过 verifyToken）；未覆盖的方法用 noSuchMethod
/// 兜成 no-op Future。
class _FakeNotificationsPlatform extends FlutterLocalNotificationsPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #initialize) {
      return Future<bool>.value(true);
    }
    return Future<void>.value();
  }
}

/// 打桩本地通知插件（applyUpdate 会调进度/完成/取消通知）。
void _mockNotifications() {
  FlutterLocalNotificationsPlatform.instance = _FakeNotificationsPlatform();
  const channels = [
    'dexterous.com/flutter/local-notifications',
    'dexterous.com/flutter/local-notifications/android',
  ];
  for (final name in channels) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (call.method == 'initialize') return true;
          return null;
        });
  }
}

AppUpdateManifest manifestWith({bool withAssets = true, bool withApp = true}) {
  return AppUpdateManifest.fromJson({
    if (withApp)
      'latest': {
        'version': '6.0.0',
        'downloads': {
          'android': {
            'url': 'https://example.com/a.apk',
            'sha256': 'aa',
            'sizeBytes': 100,
          },
        },
      },
    if (withAssets)
      'assets': {'build': 5, 'url': 'https://example.com/a.zip'},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNetworkInfo network;
  late _FakeAssetApplier applier;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockNotifications();
    network = _FakeNetworkInfo(true);
    applier = _FakeAssetApplier();
  });

  AppUpdateProvider buildProvider(AppUpdateManifest manifest) {
    return AppUpdateProvider(
      service: _FakeService(manifest),
      assetApplier: applier,
      networkInfo: network,
      currentVersionLoader: () async => '5.5.25',
      platformLoader: () async => 'android',
      abiLoader: () async => null,
    );
  }

  group('仅 WiFi 自动下载闸门', () {
    test('移动网络 + 开关开启：跳过静默资源下载，不计数', () async {
      final provider = buildProvider(manifestWith());
      await provider.initialize();
      await provider.check(manual: true);

      network.allow = false;
      await provider.applyPendingAssetsSilently();

      expect(applier.applyCount, 0);
      expect(provider.stats.assetSuccess, 0);
      expect(provider.stats.assetFailure, 0);
    });

    test('移动网络 + 开关关闭：仍然静默下载并计成功', () async {
      final provider = buildProvider(manifestWith());
      await provider.initialize();
      await provider.setWifiOnlyAutoDownload(false);
      await provider.check(manual: true);

      network.allow = false;
      await provider.applyPendingAssetsSilently();

      expect(applier.applyCount, 1);
      expect(applier.lastBuild, 5);
      expect(provider.stats.assetSuccess, 1);
    });

    test('WiFi 下（开关默认开）正常下载并写回构建号', () async {
      final provider = buildProvider(manifestWith());
      await provider.initialize();
      await provider.check(manual: true);

      await provider.applyPendingAssetsSilently();

      expect(applier.applyCount, 1);
      expect(provider.stats.assetSuccess, 1);
    });

    test('资源下载失败计失败且不推进构建号（下次可重试）', () async {
      applier.shouldThrow = true;
      final provider = buildProvider(manifestWith());
      await provider.initialize();
      await provider.check(manual: true);

      await provider.applyPendingAssetsSilently();

      expect(applier.applyCount, 1);
      expect(provider.stats.assetFailure, 1);
      expect(provider.stats.assetSuccess, 0);
    });
  });

  group('整包更新统计', () {
    test('成功拉起安装器计一次成功（实际）', () async {
      final provider = AppUpdateProvider(
        service: _FakeService(manifestWith()),
        assetApplier: applier,
        networkInfo: network,
        launcher: _FakeLauncher(
          (cancel) async => AppUpdateLaunchResult.installStarted,
        ),
        currentVersionLoader: () async => '5.5.25',
        platformLoader: () async => 'android',
        abiLoader: () async => null,
      );
      await provider.initialize();
      await provider.check(manual: true);

      final result = await provider.applyUpdate();
      expect(result, AppUpdateLaunchResult.installStarted);
      expect(provider.stats.appSuccess, 1);
    });

    test('下载抛错计一次失败并保留提示', () async {
      final provider = AppUpdateProvider(
        service: _FakeService(manifestWith()),
        assetApplier: applier,
        networkInfo: network,
        launcher: _FakeLauncher(
          (cancel) async => throw const AppUpdateException('模拟下载失败'),
        ),
        currentVersionLoader: () async => '5.5.25',
        platformLoader: () async => 'android',
        abiLoader: () async => null,
      );
      await provider.initialize();
      await provider.check(manual: true);

      final result = await provider.applyUpdate();
      expect(result, AppUpdateLaunchResult.failed);
      expect(provider.stats.appFailure, 1);
      expect(provider.message, contains('模拟下载失败'));
    });

    test('下载中取消计一次取消且不报错', () async {
      final provider = AppUpdateProvider(
        service: _FakeService(manifestWith()),
        assetApplier: applier,
        networkInfo: network,
        launcher: _FakeLauncher((isCancelled) async {
          // 模拟一个持续中的下载：等到取消标志被置位再结束。
          while (!(isCancelled?.call() ?? false)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          throw const AppUpdateException('下载已取消');
        }),
        currentVersionLoader: () async => '5.5.25',
        platformLoader: () async => 'android',
        abiLoader: () async => null,
      );
      await provider.initialize();
      await provider.check(manual: true);

      final future = provider.applyUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      provider.cancelApply();
      final result = await future;

      expect(result, AppUpdateLaunchResult.failed);
      expect(provider.stats.appCancelled, 1);
      expect(provider.stats.appFailure, 0);
      expect(provider.message, isNull);
    });

    test('清零后统计归零', () async {
      final provider = AppUpdateProvider(
        service: _FakeService(manifestWith()),
        assetApplier: applier,
        networkInfo: network,
        launcher: _FakeLauncher(
          (cancel) async => AppUpdateLaunchResult.installStarted,
        ),
        currentVersionLoader: () async => '5.5.25',
        platformLoader: () async => 'android',
        abiLoader: () async => null,
      );
      await provider.initialize();
      await provider.check(manual: true);
      await provider.applyUpdate();
      expect(provider.stats.appSuccess, 1);

      await provider.resetStats();
      expect(provider.stats.appSuccess, 0);
    });
  });
}
