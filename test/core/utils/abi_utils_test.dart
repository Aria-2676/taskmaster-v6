import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/utils/abi_utils.dart';

/// [AbiProperty.normalize] 的单测。
///
/// 刻意只测这个**纯函数**：`loadAbi()`（在 `AppUpdateProvider` 里）依赖
/// `getprop`（要起进程），在离线环境跑不动；而它的全部判定逻辑其实都在
/// normalize 里，把 normalize 测干净就覆盖了「能不能正确识别 ABI」这件事本身。
/// 探测失败时返回 null → 回落到泛化键的行为，由 decider 层的用例兜底。
void main() {
  group('AbiProperty.normalize', () {
    test('识别三种官方 ABI', () {
      expect(AbiProperty.normalize('arm64-v8a'), 'arm64-v8a');
      expect(AbiProperty.normalize('armeabi-v7a'), 'armeabi-v7a');
      expect(AbiProperty.normalize('x86_64'), 'x86_64');
    });

    test('去除首尾空白与换行（getprop 输出常带 \n）', () {
      expect(AbiProperty.normalize('  arm64-v8a\n'), 'arm64-v8a');
      expect(AbiProperty.normalize('arm64-v8a\r\n'), 'arm64-v8a');
    });

    test('大小写不敏感', () {
      expect(AbiProperty.normalize('ARM64-V8A'), 'arm64-v8a');
      expect(AbiProperty.normalize('Armeabi-V7a'), 'armeabi-v7a');
    });

    test('逗号分隔的多值取第一个可识别的', () {
      expect(
        AbiProperty.normalize('arm64-v8a,armeabi-v7a'),
        'arm64-v8a',
        reason: '多 ABI 设备上 ro.product.cpu.abi 可能是逗号分隔列表',
      );
      expect(
        AbiProperty.normalize('armeabi-v7a,arm64-v8a'),
        'armeabi-v7a',
      );
    });

    test('无法识别时返回 null（调用方据此回落泛化键）', () {
      expect(AbiProperty.normalize(null), isNull);
      expect(AbiProperty.normalize(''), isNull);
      expect(AbiProperty.normalize('   '), isNull);
      expect(AbiProperty.normalize('mips'), isNull);
      expect(AbiProperty.normalize('unknown'), isNull);
    });

    test('knownAbis 与 --split-per-abi 的产物后缀一致', () {
      // 这三个名字必须与 flutter build apk --split-per-abi 生成的
      // app-<abi>-release.apk 里的 <abi> 完全相同，否则永远匹配不上。
      expect(AbiProperty.knownAbis, containsAll(<String>[
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ]));
    });
  });
}
