import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/config/legacy_v5_link.dart';

void main() {
  group('LegacyV5Link 按机型选包', () {
    test('每种 ABI 拿自己那个包，摘要和体积各是各的', () {
      for (final abi in LegacyV5Link.artifacts.keys) {
        final target = LegacyV5Link.targetFor(abi);
        final artifact = LegacyV5Link.artifacts[abi]!;

        expect(target.url, endsWith('/${artifact.file}'),
            reason: '$abi 应该下 app-$abi-release.apk');
        expect(target.sha256, artifact.sha256);
        expect(target.sizeBytes, artifact.sizeBytes);
        // 分架构包必须比整包小 —— 否则"按机型选"就没有意义了
        expect(artifact.sizeBytes, lessThan(LegacyV5Link.fallback.sizeBytes));
      }
    });

    test('arm64 不是整包（62MB 那个坑）', () {
      final target = LegacyV5Link.targetFor('arm64-v8a');
      expect(target.url, contains('app-arm64-v8a-release.apk'));
      expect(target.sizeBytes, lessThan(30000000));
      expect(target.url, isNot(endsWith('app-release.apk')));
    });

    test('取不到 ABI 时回落整包，而不是报错', () {
      for (final unknown in <String?>[null, '', 'mips', 'ARM64-V8A ']) {
        final target = LegacyV5Link.targetFor(unknown);
        expect(target.url, endsWith('/app-release.apk'),
            reason: '「$unknown」不认识，应回落通用整包');
        expect(target.sha256, LegacyV5Link.fallback.sha256);
      }
    });

    test('镜像也跟着选中的包走（不能给整包的地址配分包的摘要）', () {
      final target = LegacyV5Link.targetFor('arm64-v8a');
      expect(target.mirrors, isNotEmpty);
      for (final mirror in target.mirrors) {
        expect(mirror, contains('app-arm64-v8a-release.apk'),
            reason: '镜像地址必须指向同一个文件：$mirror');
      }
    });

    test('确认框里的体积跟着 ABI 变', () {
      expect(LegacyV5Link.sizeLabelFor('arm64-v8a'), '约 23 MB');
      expect(LegacyV5Link.sizeLabelFor(null), '约 62 MB');
    });

    test('手动通道的地址也指向选中的包', () {
      final channels = LegacyV5Link.channelsFor('armeabi-v7a');
      final apkChannels = channels.where((c) => c.url.endsWith('.apk'));
      expect(apkChannels, isNotEmpty);
      for (final channel in apkChannels) {
        expect(channel.url, contains('app-armeabi-v7a-release.apk'));
      }
    });
  });
}
