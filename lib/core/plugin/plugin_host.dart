/// App 版本号与插件声明的"最低宿主版本"。
///
/// 为什么不用契约版本表达这件事：契约是**能力集合的大版本**（接口不兼容才动它），
/// 而"这个插件要 6.1.0"是**发行版本**的事实。两者混用会让契约变成"版本计数器"，
/// 后面就没人知道它到底代表什么。
///
/// 所以：
/// - `contract` 回答"接口还兼不兼容"；
/// - `host` 回答"至少要哪个 App 版本"。
///
/// 只实现插件生态真正会用到的语法，不做完整 semver：`>=6.1.0`、`<7.0.0`、
/// `>=6.1.0 <7.0.0`（空格分隔，全部满足才算通过）。`^`、`~`、`||` 一律不认，
/// 认不出来就当"没声明"并记日志 —— 不认识的语法不该让插件装不上。
library;

/// 只比较前三段的语义版本。
///
/// 构建号（`+6001`）不参与比较：它是发版计数，不是功能差异。
class AppSemver implements Comparable<AppSemver> {
  const AppSemver(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// 解析 `6.1.0`、`6.1.0+6001`、`6.1`。认不出来返回 null。
  static AppSemver? tryParse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    // 去掉构建号与预发布后缀：6.1.0+6001 / 6.1.0-beta.1
    final cut = text.indexOf(RegExp(r'[+\-]'));
    if (cut >= 0) text = text.substring(0, cut);
    final parts = text.split('.');
    if (parts.isEmpty || parts.length > 3) return null;

    final numbers = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 6) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0) return null;
      numbers.add(value);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return AppSemver(numbers[0], numbers[1], numbers[2]);
  }

  @override
  int compareTo(AppSemver other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(AppSemver other) => compareTo(other) < 0;
  bool operator <=(AppSemver other) => compareTo(other) <= 0;
  bool operator >(AppSemver other) => compareTo(other) > 0;
  bool operator >=(AppSemver other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is AppSemver &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// 一条比较条件：`>=6.1.0` 里的 `>=` 与 `6.1.0`。
class _Bound {
  const _Bound(this.operator, this.version);

  final String operator;
  final AppSemver version;

  bool allows(AppSemver current) {
    switch (operator) {
      case '>=':
        return current >= version;
      case '>':
        return current > version;
      case '<=':
        return current <= version;
      case '<':
        return current < version;
      default:
        return true;
    }
  }
}

/// 插件声明的最低（或区间）宿主版本，来自 manifest 的 `host`。
///
/// 缺省 = 不限制。声明了就必须**全部条件满足**才允许安装 ——
/// 这是"低于某版本的主包不支持某插件"唯一诚实的表达方式：
/// 装不上，而不是装上之后按钮点了没反应。
class PluginHostRequirement {
  const PluginHostRequirement._(this.raw, this._bounds);

  final String raw;
  final List<_Bound> _bounds;

  /// 解析 `">=6.1.0"` / `"<7.0.0"` / `">=6.1.0 <7.0.0"`。
  ///
  /// 任何一段认不出来就整体返回 null（当作没声明）：
  /// 一个写坏的 `host` 不该变成"这个插件永远装不上"。
  static PluginHostRequirement? tryParse(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;

    final bounds = <_Bound>[];
    // 允许 ">=6.1.0<7.0.0" 这种不带空格的写法
    final tokens = text
        .replaceAll('<', ' <')
        .replaceAll('>', ' >')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    for (final token in tokens) {
      final match = RegExp(r'^(>=|<=|>|<)?(.+)$').firstMatch(token);
      if (match == null) return null;
      final operator = match.group(1) ?? '>=';
      final version = AppSemver.tryParse(match.group(2));
      if (version == null) return null;
      bounds.add(_Bound(operator, version));
    }

    if (bounds.isEmpty) return null;
    return PluginHostRequirement._(text, bounds);
  }

  /// 当前 App 版本是否满足。
  bool allows(AppSemver current) {
    for (final bound in _bounds) {
      if (!bound.allows(current)) return false;
    }
    return true;
  }

  /// 给用户看的一句话（市场里标灰时用）。只说下界，区间上界对用户没意义。
  String get summary {
    for (final bound in _bounds) {
      if (bound.operator == '>=' || bound.operator == '>') {
        return '需要 App ${bound.operator}${bound.version}';
      }
    }
    final first = _bounds.first;
    return '需要 App ${first.operator}${first.version}';
  }
}
