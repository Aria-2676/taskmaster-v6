import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/plugin/plugin_host.dart';

/// 版本门槛的测试。
///
/// 这段代码的价值全在"认不出来时怎么办"：一个写错的 `host` 不能变成
/// "这个插件永远装不上"。所以每条解析路径都要有"失败就当没写"的断言。
void main() {
  group('AppSemver', () {
    test('解析 6.1.0 与带构建号的写法', () {
      expect(AppSemver.tryParse('6.1.0'), const AppSemver(6, 1, 0));
      expect(AppSemver.tryParse('6.1.0+6001'), const AppSemver(6, 1, 0));
      expect(AppSemver.tryParse(' 6.1 '), const AppSemver(6, 1, 0));
      expect(AppSemver.tryParse('6.1.0-beta.2'), const AppSemver(6, 1, 0));
    });

    test('认不出来的返回 null', () {
      expect(AppSemver.tryParse(null), isNull);
      expect(AppSemver.tryParse(''), isNull);
      expect(AppSemver.tryParse('v6.1.0'), isNull);
      expect(AppSemver.tryParse('6.1.0.1'), isNull);
      expect(AppSemver.tryParse('6.-1.0'), isNull);
    });

    test('按段比较，不是按字符串', () {
      expect(const AppSemver(6, 10, 0) > const AppSemver(6, 9, 9), isTrue);
      expect(const AppSemver(7, 0, 0) > const AppSemver(6, 99, 99), isTrue);
      expect(const AppSemver(6, 1, 0) == const AppSemver(6, 1, 0), isTrue);
    });
  });

  group('PluginHostRequirement', () {
    test('下界：6.1.0 装了要求 >=6.1.0 的插件', () {
      final req = PluginHostRequirement.tryParse('>=6.1.0')!;
      expect(req.allows(const AppSemver(6, 1, 0)), isTrue);
      expect(req.allows(const AppSemver(6, 0, 6)), isFalse);
      expect(req.allows(const AppSemver(7, 0, 0)), isTrue);
    });

    test('区间：>=6.1.0 <7.0.0', () {
      final req = PluginHostRequirement.tryParse('>=6.1.0 <7.0.0')!;
      expect(req.allows(const AppSemver(6, 1, 0)), isTrue);
      expect(req.allows(const AppSemver(6, 9, 9)), isTrue);
      expect(req.allows(const AppSemver(7, 0, 0)), isFalse);
      expect(req.allows(const AppSemver(6, 0, 9)), isFalse);
    });

    test('带不带空格都能认', () {
      expect(PluginHostRequirement.tryParse('>=6.1.0<7.0.0')!.allows(const AppSemver(6, 2, 0)), isTrue);
      expect(PluginHostRequirement.tryParse('>=6.1.0<7.0.0')!.allows(const AppSemver(7, 0, 0)), isFalse);
    });

    test('只有上界也能用', () {
      final req = PluginHostRequirement.tryParse('<7.0.0')!;
      expect(req.allows(const AppSemver(6, 0, 0)), isTrue);
      expect(req.allows(const AppSemver(7, 0, 0)), isFalse);
    });

    test('认不出来当没声明，不把插件锁死', () {
      expect(PluginHostRequirement.tryParse(null), isNull);
      expect(PluginHostRequirement.tryParse(''), isNull);
      expect(PluginHostRequirement.tryParse('^6.1.0'), isNull);
      expect(PluginHostRequirement.tryParse('>=6.1.0 || >=7.0.0'), isNull);
      expect(PluginHostRequirement.tryParse(42), isNull);
    });

    test('summary 只说下界（上界对用户没意义）', () {
      expect(PluginHostRequirement.tryParse('>=6.1.0 <7.0.0')!.summary, '需要 App >=6.1.0');
      expect(PluginHostRequirement.tryParse('<7.0.0')!.summary, '需要 App <7.0.0');
    });
  });
}
