import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/updater/models/app_update_manifest.dart';
import 'package:v5_app/core/utils/version_utils.dart';

void main() {
  group('AppUpdateManifest', () {
    test('根节点不是对象时应抛 FormatException', () {
      expect(() => AppUpdateManifest.fromJson('nope'), throwsFormatException);
      expect(() => AppUpdateManifest.fromJson(null), throwsFormatException);
    });

    test('应解析出整包版本与各平台产物', () {
      final manifest = AppUpdateManifest.fromJson({
        'schemaVersion': 2,
        'updatedAt': '2026-10-09T14:30:00Z',
        'minSupported': '5.0.0',
        'latest': {
          'version': '6.0.0',
          'level': 'major',
          'notes': ['新增坦克大战', '修复白屏'],
          'downloads': {
            'android': {
              'url': 'https://example.com/a.apk',
              'sha256': 'ABCDEF',
              'sizeBytes': 1024,
            },
          },
        },
      });

      expect(manifest.schemaVersion, 2);
      expect(manifest.updatedAt, isNotNull);
      expect(manifest.minSupported, '5.0.0');
      expect(manifest.release!.version, '6.0.0');
      expect(manifest.release!.declaredLevel, VersionChangeLevel.major);
      expect(manifest.release!.notes, ['新增坦克大战', '修复白屏']);
      // sha256 统一转小写，避免大小写不一致导致校验误判。
      expect(manifest.release!.downloads['android']!.sha256, 'abcdef');
      expect(manifest.release!.downloads['android']!.sizeBytes, 1024);
    });

    test('minSupported 不含数字时应视为未设置', () {
      final manifest = AppUpdateManifest.fromJson({
        'minSupported': 'next',
      });
      expect(manifest.minSupported, isNull);
    });

    test('latest 版本号非法时丢弃整包，但不影响 assets', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {'version': 'vNext'},
        'assets': {'build': 7, 'url': 'https://example.com/a.zip'},
      });
      expect(manifest.release, isNull);
      expect(manifest.assets, isNotNull);
      expect(manifest.assets!.build, 7);
    });

    test('downloads 里非 http(s) 地址应被丢弃', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {
          'version': '6.0.0',
          'downloads': {
            'android': {'url': 'https://ok.com/a.apk'},
            'windows': {'url': 'file:///C:/evil.exe'},
            'ios': {'url': 'javascript:alert(1)'},
          },
        },
      });

      final downloads = manifest.release!.downloads;
      expect(downloads.containsKey('android'), isTrue);
      expect(downloads.containsKey('windows'), isFalse);
      expect(downloads.containsKey('ios'), isFalse);
    });

    test('downloads 全部非法时该版本仍存在但没有平台可用', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {
          'version': '6.0.0',
          'downloads': {
            'android': {'url': 'ftp://x/a.apk'},
          },
        },
      });
      expect(manifest.release, isNotNull);
      expect(manifest.release!.supportsPlatform('android'), isFalse);
    });

    test('notes 支持用换行分隔的字符串', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {
          'version': '6.0.0',
          'notes': '第一条\n\n  第二条  \n',
        },
      });
      expect(manifest.release!.notes, ['第一条', '第二条']);
    });

    test('level 缺省时按版本号差值推断', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {'version': '6.0.0'},
      });
      final release = manifest.release!;
      expect(release.declaredLevel, isNull);
      expect(release.levelAgainst('5.5.10'), VersionChangeLevel.major);
      expect(release.levelAgainst('6.0.0'), VersionChangeLevel.patch);
    });

    test('level 显式声明优先于推断', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {'version': '5.5.11', 'level': 'major'},
      });
      expect(
        manifest.release!.levelAgainst('5.5.10'),
        VersionChangeLevel.major,
      );
    });

    test('level 写了非法值时应回落到推断', () {
      final manifest = AppUpdateManifest.fromJson({
        'latest': {'version': '5.5.11', 'level': 'huge'},
      });
      expect(manifest.release!.declaredLevel, isNull);
      expect(
        manifest.release!.levelAgainst('5.5.10'),
        VersionChangeLevel.patch,
      );
    });

    test('assets 构建号必须为正整数', () {
      expect(
        AppUpdateManifest.fromJson({
          'assets': {'build': 0, 'url': 'https://x/a.zip'},
        }).assets,
        isNull,
      );
      expect(
        AppUpdateManifest.fromJson({
          'assets': {'build': -1, 'url': 'https://x/a.zip'},
        }).assets,
        isNull,
      );
      expect(
        AppUpdateManifest.fromJson({
          'assets': {'build': '3', 'url': 'https://x/a.zip'},
        }).assets,
        isNull,
      );
    });

    test('assets 地址非法时丢弃', () {
      expect(
        AppUpdateManifest.fromJson({
          'assets': {'build': 3, 'url': 'file:///C:/x.zip'},
        }).assets,
        isNull,
      );
    });

    test('assets.mirrors 只保留 http(s)，非法项静默丢弃', () {
      final assets = AppUpdateManifest.fromJson({
        'assets': {
          'build': 3,
          'url': 'https://primary.example.com/a.zip',
          'mirrors': [
            'https://mirror-a.example.com/a.zip',
            'http://mirror-b.example.com/a.zip',
            'file:///C:/evil.zip',
            'javascript:alert(1)',
            'not-a-url',
          ],
        },
      }).assets!;

      expect(assets.mirrors, [
        'https://mirror-a.example.com/a.zip',
        'http://mirror-b.example.com/a.zip',
      ]);
    });

    test('assets 缺省 mirrors 为空列表且 toJson 省略该字段', () {
      final assets = AppUpdateManifest.fromJson({
        'assets': {'build': 3, 'url': 'https://x/a.zip'},
      }).assets!;
      expect(assets.mirrors, isEmpty);
      final json = assets.toJson();
      expect(json.containsKey('mirrors'), isFalse);
    });

    test('应忽略未知字段（例如 _comment）', () {
      final manifest = AppUpdateManifest.fromJson({
        '_comment': ['随便写点什么'],
        'latest': {'version': '6.0.0'},
      });
      expect(manifest.release!.version, '6.0.0');
    });

    test('toJson → fromJson 往返应保持一致', () {
      final source = AppUpdateManifest.fromJson({
        'schemaVersion': 1,
        'minSupported': '5.0.0',
        'latest': {
          'version': '6.0.0',
          'level': 'minor',
          'notes': ['a'],
          'downloads': {
            'android': {'url': 'https://x/a.apk', 'sha256': 'FF', 'sizeBytes': 9},
          },
        },
        'assets': {'build': 3, 'url': 'https://x/a.zip', 'sha256': 'AA'},
      });

      final roundTrip = AppUpdateManifest.fromJson(source.toJson());
      expect(roundTrip.schemaVersion, source.schemaVersion);
      expect(roundTrip.minSupported, source.minSupported);
      expect(roundTrip.release!.version, source.release!.version);
      expect(roundTrip.release!.declaredLevel, source.release!.declaredLevel);
      expect(roundTrip.release!.notes, source.release!.notes);
      expect(
        roundTrip.release!.downloads['android']!.sha256,
        source.release!.downloads['android']!.sha256,
      );
      expect(roundTrip.assets!.build, source.assets!.build);
      expect(roundTrip.assets!.sha256, source.assets!.sha256);
    });

    test('hasAnyUpdate 反映是否解析出任何内容', () {
      expect(AppUpdateManifest.fromJson({}).hasAnyUpdate, isFalse);
      expect(
        AppUpdateManifest.fromJson({
          'assets': {'build': 1, 'url': 'https://x/a.zip'},
        }).hasAnyUpdate,
        isTrue,
      );
    });
  });

  group('AppRelease.resolveTarget（ABI 细分 + 回落）', () {
    AppRelease releaseWith(Map<String, Object> downloads) => AppRelease(
      version: '6.0.0',
      downloads: downloads.map(
        (key, value) => MapEntry(key, AppDownloadTarget.tryFromJson(value)!),
      ),
    );

    Map<String, Object> apk(String name) => {
      'url': 'https://example.com/$name',
      'sha256': 'aa',
      'sizeBytes': 100,
    };

    test('有精确 ABI 键时优先取它，而不是泛化键', () {
      final release = releaseWith({
        'android': apk('fat.apk'),
        'android-arm64-v8a': apk('arm64.apk'),
      });

      final picked = release.resolveTarget('android', abi: 'arm64-v8a');
      expect(picked!.url, 'https://example.com/arm64.apk');
    });

    test('没有精确 ABI 键时回落到泛化键', () {
      final release = releaseWith({'android': apk('fat.apk')});

      final picked = release.resolveTarget('android', abi: 'arm64-v8a');
      expect(picked!.url, 'https://example.com/fat.apk');
    });

    test('不传 abi 时等价于旧的 downloads[platform] 行为', () {
      final release = releaseWith({
        'android': apk('fat.apk'),
        'android-arm64-v8a': apk('arm64.apk'),
      });

      expect(release.resolveTarget('android')!.url, 'https://example.com/fat.apk');
    });

    test('ABI 大小写不敏感（getprop 输出可能大小写不一）', () {
      final release = releaseWith({'android-ARM64-V8A': apk('arm64.apk')});
      expect(
        release.resolveTarget('android', abi: 'ARM64-V8A')!.url,
        'https://example.com/arm64.apk',
      );
    });

    test('平台或 ABI 都没有对应产物时返回 null', () {
      final release = releaseWith({'ios': apk('ios.ipa')});
      expect(release.resolveTarget('android'), isNull);
      expect(release.resolveTarget('android', abi: 'arm64-v8a'), isNull);
    });

    test('空 abi 字符串等同不传（不产生 android- 这种空后缀键）', () {
      final release = releaseWith({'android': apk('fat.apk')});
      expect(release.resolveTarget('android', abi: '')!.url,
          'https://example.com/fat.apk');
      expect(release.resolveTarget('android', abi: '   ')!.url,
          'https://example.com/fat.apk');
    });
  });
}
