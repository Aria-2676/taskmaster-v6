/// 首页形态：内置任务模式，或者某个插件提供的整页。
///
/// **外壳不参与替换**：底栏、侧边栏、添加按钮永远由主包画。
/// 插件只填中间那块内容区 —— 否则插件一旦崩了，用户连"去哪儿关掉它"都找不到。
class HomeMode {
  const HomeMode.builtin() : pluginId = null;

  const HomeMode.plugin(String this.pluginId);

  /// null = 内置
  final String? pluginId;

  bool get isBuiltin => pluginId == null;

  static const String _prefix = 'plugin:';

  static HomeMode parse(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'builtin') {
      return const HomeMode.builtin();
    }
    if (raw.startsWith(_prefix)) {
      final id = raw.substring(_prefix.length).trim();
      if (id.isNotEmpty) return HomeMode.plugin(id);
    }
    // 认不出来就当内置：首页的解析失败必须是"能用"，不能是"打不开"
    return const HomeMode.builtin();
  }

  String encode() => pluginId == null ? 'builtin' : '$_prefix$pluginId';

  @override
  bool operator ==(Object other) =>
      other is HomeMode && other.pluginId == pluginId;

  @override
  int get hashCode => pluginId.hashCode;

  @override
  String toString() => encode();
}
