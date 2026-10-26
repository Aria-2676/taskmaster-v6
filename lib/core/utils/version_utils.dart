/// 版本号比较工具。
///
/// 仅支持 `major.minor.patch` 三元组数值比较，不做 semver 范围匹配：
/// 调用方只需回答「远端版本是否比本地新」，越简单越不容易出错。
///
/// 游戏包与 App 更新包共用同一套比较规则，因此放在 `core` 下。
class VersionUtils {
  const VersionUtils._();

  static final RegExp _versionPrefix = RegExp(r'^[vV]');
  static final RegExp _leadingDigits = RegExp(r'^\d+');
  static final RegExp _hasDigit = RegExp(r'\d');

  /// 解析版本号字符串为三元组；无法解析的部分按 0 处理。
  ///
  /// 支持 `1.2.3`、`v1.2.3`、`1.2.3-beta` 等形式，非数字后缀被忽略。
  static List<int> parse(String version) {
    final cleaned = version.trim().replaceFirst(_versionPrefix, '');
    final parts = cleaned.split('.');
    final result = <int>[0, 0, 0];
    for (var i = 0; i < 3 && i < parts.length; i++) {
      final match = _leadingDigits.firstMatch(parts[i]);
      result[i] = match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0);
    }
    return result;
  }

  /// 比较两个版本号。
  ///
  /// 返回负数表示 [a] 更旧，0 表示相同，正数表示 [a] 更新。
  ///
  /// 逐位数值比较而非字符串比较：`1.0.10` 比 `1.0.9` 新，字符串序会判反。
  static int compare(String a, String b) {
    final left = parse(a);
    final right = parse(b);
    for (var i = 0; i < 3; i++) {
      if (left[i] != right[i]) return left[i] - right[i];
    }
    return 0;
  }

  /// 判断 [candidate] 是否比 [current] 更新。
  static bool isNewer(String candidate, String current) {
    return compare(candidate, current) > 0;
  }

  /// 版本号是否合法（至少包含一个数字）。
  static bool isValid(String version) {
    return _hasDigit.hasMatch(version);
  }

  /// 两个版本号之间的差异级别：主版本 / 次版本 / 修订号不同。
  ///
  /// 用于把「更新」分级：主版本变化才值得弹窗打扰用户，修订号变化适合静默处理。
  static VersionChangeLevel differenceLevel(String candidate, String current) {
    final left = parse(candidate);
    final right = parse(current);
    if (left[0] != right[0]) return VersionChangeLevel.major;
    if (left[1] != right[1]) return VersionChangeLevel.minor;
    return VersionChangeLevel.patch;
  }
}

/// 两个版本号之间的差异级别。
enum VersionChangeLevel { patch, minor, major }
