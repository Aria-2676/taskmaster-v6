import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/utils/version_utils.dart';

void main() {
  group('VersionUtils', () {
    test('parse 应解析标准三元组', () {
      expect(VersionUtils.parse('1.2.3'), [1, 2, 3]);
    });

    test('parse 应忽略 v 前缀', () {
      expect(VersionUtils.parse('v1.2.3'), [1, 2, 3]);
      expect(VersionUtils.parse('V1.2.3'), [1, 2, 3]);
    });

    test('parse 应忽略预发布后缀', () {
      expect(VersionUtils.parse('1.2.3-beta.1'), [1, 2, 3]);
    });

    test('parse 缺位应补零', () {
      expect(VersionUtils.parse('1.2'), [1, 2, 0]);
      expect(VersionUtils.parse('1'), [1, 0, 0]);
    });

    test('parse 无法解析时返回全零', () {
      expect(VersionUtils.parse('abc'), [0, 0, 0]);
      expect(VersionUtils.parse(''), [0, 0, 0]);
    });

    test('compare 应按数值而非字符串比较', () {
      // 字符串序会判反：'1.10.0' < '1.9.9'，数值序相反。
      expect(VersionUtils.compare('1.10.0', '1.9.9'), greaterThan(0));
      expect(VersionUtils.compare('1.0.10', '1.0.9'), greaterThan(0));
    });

    test('compare 相同版本为 0', () {
      expect(VersionUtils.compare('2.0.0', '2.0.0'), 0);
      expect(VersionUtils.compare('v2.0.0', '2.0.0'), 0);
    });

    test('compare 旧版本为负', () {
      expect(VersionUtils.compare('1.0.0', '1.0.1'), lessThan(0));
    });

    test('isNewer 应判断严格更新', () {
      expect(VersionUtils.isNewer('1.10.0', '1.9.9'), isTrue);
      expect(VersionUtils.isNewer('2.0.0', '2.0.0'), isFalse);
      expect(VersionUtils.isNewer('1.0.0', '1.0.1'), isFalse);
    });

    test('isValid 至少要含一个数字', () {
      expect(VersionUtils.isValid('1.0.0'), isTrue);
      expect(VersionUtils.isValid('v2'), isTrue);
      expect(VersionUtils.isValid('beta'), isFalse);
      expect(VersionUtils.isValid(''), isFalse);
    });

    group('differenceLevel', () {
      test('主版本变化', () {
        expect(
          VersionUtils.differenceLevel('6.0.0', '5.5.10'),
          VersionChangeLevel.major,
        );
      });

      test('次版本变化', () {
        expect(
          VersionUtils.differenceLevel('5.6.0', '5.5.10'),
          VersionChangeLevel.minor,
        );
      });

      test('修订号变化', () {
        expect(
          VersionUtils.differenceLevel('5.5.11', '5.5.10'),
          VersionChangeLevel.patch,
        );
      });

      test('相同版本视为修订号级别', () {
        expect(
          VersionUtils.differenceLevel('5.5.10', '5.5.10'),
          VersionChangeLevel.patch,
        );
      });
    });
  });
}
