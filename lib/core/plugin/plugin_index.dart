import 'plugin_manifest.dart';

/// 索引里的一项：一句话描述 + 从哪儿下。
///
/// 索引**不含** manifest 全文 —— 安装后才以包内 `plugin.json` 为准。
/// 这样可以避免"索引说 1.0、包里是 2.0"这种不一致。
///
/// 唯一的例外是 [permissions]：它必须**在下载之前**就知道，否则没法在安装前
/// 告诉用户"这个插件能改你的任务"。所以索引里带一份，由打包脚本从
/// `plugin.json` 复制而来；真正生效的授权仍然以包内 manifest 为准。
class PluginIndexEntry {
  const PluginIndexEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.contract,
    required this.package,
    this.description,
    this.icon,
    this.permissions = const <String>{},
    this.home,
  });

  factory PluginIndexEntry.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final version = json['version'];
    final contract = json['contract'];

    if (id is! String || !PluginManifest.idPattern.hasMatch(id)) {
      throw PluginFormatException('索引项 id 非法：$id');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const PluginFormatException('索引项 name 不能为空');
    }
    if (version is! String || !PluginManifest.versionPattern.hasMatch(version)) {
      throw PluginFormatException('索引项 version 必须是 x.y.z：$version');
    }
    if (contract is! int) {
      throw const PluginFormatException('索引项 contract 必须是整数');
    }

    final pkg = json['package'];
    if (pkg is! Map) {
      throw PluginFormatException('索引项 $id 缺少 package');
    }

    return PluginIndexEntry(
      id: id,
      name: name.trim(),
      version: version,
      contract: contract,
      description: json['description'] is String ? json['description']! as String : null,
      icon: json['icon'] is String ? json['icon']! as String : null,
      permissions: _parsePermissions(json['permissions']),
      home: PluginHomeSpec.tryParse(json['home']),
      package: PluginPackage.fromJson(Map<String, Object?>.from(pkg)),
    );
  }

  /// 不认识的权限直接丢掉（老宿主遇到新权限时，少显示一条好过装不上）。
  static Set<String> _parsePermissions(Object? raw) {
    if (raw is! List) return const <String>{};
    return <String>{
      for (final item in raw)
        if (item is String && PluginManifest.knownPermissions.contains(item)) item,
    };
  }

  final String id;
  final String name;
  final String version;
  final int contract;
  final String? description;
  final String? icon;

  /// 安装前要展示给用户的权限（**展示用**；生效的是包内 manifest）
  final Set<String> permissions;

  /// 可当首页模式的声明（同样从 `plugin.json` 复制，理由同 [permissions]）：
  /// 顶栏的快捷切换拿的是**已装插件**的清单，而它的显示名来自索引 ——
  /// 不带这一段，模式名就只能退回插件的长名字。
  final PluginHomeSpec? home;

  final PluginPackage package;

  /// 当前宿主能不能装这一项
  bool get installable => PluginContract.accepts(contract);
}

/// `plugins/index.json`。
///
/// 设计原则：**索引是信任根**，但不是权威内容。它决定"有哪些可装"，
/// 装完之后一切以包内 `plugin.json` 为准。
class PluginIndex {
  const PluginIndex({
    required this.schemaVersion,
    required this.plugins,
    this.publishedAt,
  });

  factory PluginIndex.parse(Map<String, Object?> json) {
    final schema = json['schemaVersion'];
    if (schema is! int) {
      throw const PluginFormatException('索引缺少 schemaVersion');
    }
    if (schema != supportedSchema) {
      throw PluginFormatException(
        '索引 schemaVersion=$schema 不受支持（当前 $supportedSchema）',
      );
    }

    final raw = json['plugins'];
    if (raw is! List) {
      throw const PluginFormatException('索引缺少 plugins 数组');
    }

    final seen = <String>{};
    final entries = <PluginIndexEntry>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const PluginFormatException('plugins 里有一项不是对象');
      }
      final entry = PluginIndexEntry.fromJson(Map<String, Object?>.from(item));
      // 重复 id 会让"装的是哪个"变成不确定的，直接判为坏索引
      if (!seen.add(entry.id)) {
        throw PluginFormatException('索引里 id 重复：${entry.id}');
      }
      entries.add(entry);
    }

    // 发布时刻。**缺少就是 null**（老索引没有这个字段，别把它当坏索引）。
    final rawPublished = json['publishedAt'];
    final publishedAt =
        rawPublished is String ? DateTime.tryParse(rawPublished) : null;

    return PluginIndex(
      schemaVersion: schema,
      plugins: entries,
      publishedAt: publishedAt,
    );
  }

  static const int supportedSchema = 1;

  /// 空索引：首版"货架"用它，避免为了一个空列表去联网。
  static const PluginIndex empty = PluginIndex(schemaVersion: supportedSchema, plugins: <PluginIndexEntry>[]);

  final int schemaVersion;
  final List<PluginIndexEntry> plugins;

  /// 这份索引是什么时候生成的（UTC）。客户端在几个 CDN 节点之间**比新旧**用它。
  ///
  /// 老索引没有这个字段 → null，按"最旧"处理：任何带时间戳的都赢它。
  final DateTime? publishedAt;

  PluginIndexEntry? findById(String id) {
    for (final p in plugins) {
      if (p.id == id) return p;
    }
    return null;
  }
}
