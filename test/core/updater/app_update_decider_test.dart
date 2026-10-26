import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/updater/models/app_update_decision.dart';
import 'package:v5_app/core/updater/models/app_update_manifest.dart';
import 'package:v5_app/core/updater/services/app_update_decider.dart';
import 'package:v5_app/core/utils/version_utils.dart';

const String _current = '5.5.10';

/// 构造一份「有整包更新」的清单。
///
/// 注意 [version] 默认为 `6.0.0`，即**一定**比 [_current] 新。
/// 只想验证「资源热更」而**不**希望掺入整包更新时，用
/// [manifestWithAssetsOnly]——它把版本设成当前版本，整包分支不会命中。
AppUpdateManifest manifestWithRelease({
  String version = '6.0.0',
  String? level,
  String? minSupported,
  List<String> platforms = const ['android'],
  int? assetBuild,
  String assetUrl = 'https://example.com/assets.zip',
}) {
  return AppUpdateManifest.fromJson({
    'minSupported': ?minSupported,
    'latest': {
      'version': version,
      'level': ?level,
      'downloads': {
        for (final platform in platforms)
          platform: {'url': 'https://example.com/app-$platform'},
      },
    },
    if (assetBuild != null)
      'assets': {'build': assetBuild, 'url': assetUrl},
  });
}

/// 构造一份**只有资源热更、没有整包更新**的清单（版本等于当前版本）。
///
/// 用它来测资源分支，避免误用 [manifestWithRelease] 的 `6.0.0` 默认值——
/// 那样会命中整包分支，断言到 `optional` 而不是 `assetsOnly`。
AppUpdateManifest manifestWithAssetsOnly({
  int assetBuild = 3,
  String assetUrl = 'https://example.com/assets.zip',
}) {
  return AppUpdateManifest.fromJson({
    'latest': {
      'version': _current,
      'downloads': {
        'android': {'url': 'https://example.com/app-android'},
      },
    },
    'assets': {'build': assetBuild, 'url': assetUrl},
  });
}

AppUpdateDecision decide(
  AppUpdateManifest? manifest, {
  String platform = 'android',
  String? abi,
  int currentAssetBuild = 0,
  String? ignoredVersion,
  bool notificationsDisabled = false,
}) {
  return AppUpdateDecider.decide(
    manifest: manifest,
    currentVersion: _current,
    platform: platform,
    abi: abi,
    currentAssetBuild: currentAssetBuild,
    ignoredVersion: ignoredVersion,
    notificationsDisabled: notificationsDisabled,
  );
}

void main() {
  group('AppUpdateDecider 无更新场景', () {
    test('清单为 null 时应静默返回无更新', () {
      final decision = decide(null);
      expect(decision.kind, AppUpdateKind.none);
      expect(decision.hasUpdate, isFalse);
      expect(decision.shouldPrompt, isFalse);
      expect(decision.reason, contains('未获取到'));
    });

    test('版本相同应返回无更新', () {
      final decision = decide(manifestWithRelease(version: _current));
      expect(decision.kind, AppUpdateKind.none);
    });

    test('本地版本更新时应返回无更新', () {
      final decision = decide(manifestWithRelease(version: '5.5.9'));
      expect(decision.kind, AppUpdateKind.none);
    });

    test('空清单应返回无更新', () {
      final decision = decide(AppUpdateManifest.fromJson({}));
      expect(decision.kind, AppUpdateKind.none);
    });
  });

  group('AppUpdateDecider 整包更新分级', () {
    test('主版本变化应弹窗且可关闭', () {
      final decision = decide(manifestWithRelease(version: '6.0.0'));
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.shouldPrompt, isTrue);
      expect(decision.canDismiss, isTrue);
      expect(decision.effectiveLevel, VersionChangeLevel.major);
      expect(decision.release!.version, '6.0.0');
    });

    test('次版本变化也弹窗（自签分发无商店兜底）', () {
      final decision = decide(manifestWithRelease(version: '5.6.0'));
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.shouldPrompt, isTrue);
      expect(decision.effectiveLevel, VersionChangeLevel.minor);
    });

    test('修订号变化也弹窗（补丁可能含紧急修复）', () {
      final decision = decide(manifestWithRelease(version: '5.5.11'));
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.shouldPrompt, isTrue);
      expect(decision.effectiveLevel, VersionChangeLevel.patch);
    });

    test('显式声明 major 时按声明的级别展示', () {
      final decision = decide(
        manifestWithRelease(version: '5.5.11', level: 'major'),
      );
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.effectiveLevel, VersionChangeLevel.major);
    });
  });

  group('AppUpdateDecider 强制更新', () {
    test('低于最低支持版本应强制且不可关闭', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', minSupported: '5.6.0'),
      );
      expect(decision.kind, AppUpdateKind.forced);
      expect(decision.canDismiss, isFalse);
      expect(decision.shouldPrompt, isTrue);
      expect(decision.reason, contains('5.6.0'));
    });

    test('即使没有整包产物也应强制', () {
      final manifest = AppUpdateManifest.fromJson({'minSupported': '6.0.0'});
      final decision = decide(manifest);
      expect(decision.kind, AppUpdateKind.forced);
    });

    test('最低支持版本等于当前版本时不强制（边界）', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', minSupported: _current),
      );
      expect(decision.kind, AppUpdateKind.optional);
    });

    test('强制更新不受「关闭提醒」影响', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', minSupported: '5.6.0'),
        notificationsDisabled: true,
      );
      expect(decision.kind, AppUpdateKind.forced);
      expect(decision.canDismiss, isFalse);
    });

    test('强制更新不受「跳过此版本」影响', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', minSupported: '5.6.0'),
        ignoredVersion: '6.0.0',
      );
      expect(decision.kind, AppUpdateKind.forced);
    });
  });

  group('AppUpdateDecider 用户抑制', () {
    test('关闭提醒后主版本更新降级为设置页提示而非消失', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0'),
        notificationsDisabled: true,
      );
      expect(decision.kind, AppUpdateKind.available);
      expect(decision.shouldPrompt, isFalse);
      expect(decision.hasRelease, isTrue);
      expect(decision.reason, contains('忽略'));
    });

    test('跳过该版本后不再弹窗，但仍可看到', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0'),
        ignoredVersion: '6.0.0',
      );
      expect(decision.kind, AppUpdateKind.available);
      expect(decision.shouldPrompt, isFalse);
    });

    test('跳过的是别的版本时仍应弹窗', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0'),
        ignoredVersion: '6.1.0',
      );
      expect(decision.kind, AppUpdateKind.optional);
    });
  });

  group('AppUpdateDecider 平台过滤', () {
    test('清单没有该平台产物时不提示整包更新', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', platforms: ['ios']),
        platform: 'android',
      );
      expect(decision.kind, AppUpdateKind.none);
      expect(decision.release, isNull);
      expect(decision.reason, contains('android'));
    });

    test('平台不匹配但资源可更新时应只做资源热更', () {
      final decision = decide(
        manifestWithRelease(
          version: '6.0.0',
          platforms: ['ios'],
          assetBuild: 3,
        ),
        platform: 'android',
      );
      expect(decision.kind, AppUpdateKind.assetsOnly);
      expect(decision.assets!.build, 3);
    });
  });

  group('AppUpdateDecider 资源热更新', () {
    test('首次安装（本地构建号 0）应判定为有资源更新', () {
      final decision = decide(manifestWithAssetsOnly(assetBuild: 3));
      expect(decision.kind, AppUpdateKind.assetsOnly);
      expect(decision.shouldPrompt, isFalse);
      expect(decision.hasAssets, isTrue);
    });

    test('构建号相同不算更新', () {
      final decision = decide(
        manifestWithAssetsOnly(assetBuild: 3),
        currentAssetBuild: 3,
      );
      expect(decision.kind, AppUpdateKind.none);
      expect(decision.assets, isNull);
    });

    test('本地构建号更大时不算更新（防止回滚到旧包）', () {
      final decision = decide(
        manifestWithAssetsOnly(assetBuild: 3),
        currentAssetBuild: 9,
      );
      expect(decision.kind, AppUpdateKind.none);
    });

    test('整包与资源同时可用时以整包为主，但资源一并带上', () {
      final decision = decide(
        manifestWithRelease(version: '6.0.0', assetBuild: 3),
      );
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.hasRelease, isTrue);
      expect(decision.hasAssets, isTrue);
    });

    test('补丁版本叠加资源更新时同样弹窗并带上资源', () {
      final decision = decide(
        manifestWithRelease(version: '5.5.11', assetBuild: 3),
      );
      expect(decision.kind, AppUpdateKind.optional);
      expect(decision.hasAssets, isTrue);
    });
  });

  group('ABI 细分产物（split-per-abi 分发）', () {
    /// 只提供 ABI 细分键、**没有**泛化 `android` 键的清单。
    /// 这正是「只发 split 包」时的形态，旧客户端会在这里静默失联。
    AppUpdateManifest manifestAbiOnly() => AppUpdateManifest.fromJson({
      'latest': {
        'version': '6.0.0',
        'downloads': {
          'android-arm64-v8a': {'url': 'https://example.com/arm64.apk'},
          'android-armeabi-v7a': {'url': 'https://example.com/v7a.apk'},
        },
      },
    });

    test('有泛化键时：不带 abi 的老客户端仍能收到更新', () {
      final decision = decide(manifestWithRelease(version: '6.0.0'));
      expect(decision.kind, AppUpdateKind.optional);
    });

    test('只有 ABI 键时：不带 abi 会判定为无产物（这暴露了兼容风险）', () {
      final decision = decide(manifestAbiOnly());
      expect(
        decision.kind,
        AppUpdateKind.none,
        reason: '清单没有泛化 android 键 → 旧客户端查不到，更新静默消失',
      );
      expect(decision.reason, contains('android'));
    });

    test('只有 ABI 键时：带正确 abi 就能正常判定为有更新', () {
      final decision = decide(manifestAbiOnly(), abi: 'arm64-v8a');
      expect(decision.kind, AppUpdateKind.optional);
    });

    test('abi 不匹配且无泛化键时，回落失败并给出可用键便于排查', () {
      final decision = decide(manifestAbiOnly(), abi: 'x86_64');
      expect(decision.kind, AppUpdateKind.none);
      // reason 里应列出实际可用的键，避免「为什么没匹配上」无从查起。
      expect(decision.reason, contains('android-arm64-v8a'));
    });
  });

  group('AppUpdateDecision 语义', () {
    test('none 常量的语义正确', () {
      expect(AppUpdateDecision.none.kind, AppUpdateKind.none);
      expect(AppUpdateDecision.none.hasUpdate, isFalse);
      expect(AppUpdateDecision.none.canDismiss, isTrue);
    });

    test('toString 应包含关键信息便于排查', () {
      final decision = decide(manifestWithRelease(version: '6.0.0'));
      expect(decision.toString(), contains('optional'));
      expect(decision.toString(), contains('6.0.0'));
    });
  });
}
