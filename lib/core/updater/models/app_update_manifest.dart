import '../../utils/version_utils.dart';

/// App 更新清单（`update.json`）的解析结果。
///
/// 设计原则与游戏清单一致：**顶层结构非法 → 抛 [FormatException]；
/// 局部字段非法 → 丢弃该局部而不是整份失败**。更新清单是外网文件，
/// 一个笔误不该让整个「版本检查」功能瘫痪。
class AppUpdateManifest {
  /// 清单结构版本，用于将来做兼容处理。
  final int schemaVersion;

  /// 清单生成时间。
  final DateTime? updatedAt;

  /// 最低可支持的客户端版本；低于它的客户端**强制**更新。
  ///
  /// 留空表示不强制。用于旧版协议不兼容、必须换包的情况。
  final String? minSupported;

  /// 最新的整包版本；为 null 表示当前没有整包更新。
  final AppRelease? release;

  /// 资源热更新包；为 null 表示没有资源更新。
  final AssetUpdatePackage? assets;

  const AppUpdateManifest({
    required this.schemaVersion,
    this.updatedAt,
    this.minSupported,
    this.release,
    this.assets,
  });

  /// 从 JSON 解析。
  ///
  /// [FormatException] 只在「根节点不是对象」时抛出。
  factory AppUpdateManifest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('更新清单根节点必须是 JSON 对象');
    }

    final schema = raw['schemaVersion'];
    final minSupportedRaw = raw['minSupported'];

    return AppUpdateManifest(
      schemaVersion: schema is int ? schema : 1,
      updatedAt: DateTime.tryParse(raw['updatedAt']?.toString() ?? ''),
      // 版本号至少要含一个数字才认；否则视为未设置（宁可漏提示，不可误强制）。
      minSupported:
          minSupportedRaw is String && VersionUtils.isValid(minSupportedRaw)
          ? minSupportedRaw
          : null,
      release: AppRelease.tryFromJson(raw['latest'] ?? raw['release']),
      assets: AssetUpdatePackage.tryFromJson(raw['assets']),
    );
  }

  /// 是否存在任何可用更新。
  bool get hasAnyUpdate => release != null || assets != null;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
    if (minSupported != null) 'minSupported': minSupported,
    if (release != null) 'latest': release!.toJson(),
    if (assets != null) 'assets': assets!.toJson(),
  };
}

/// 一个可下载的整包产物（按平台区分）。
class AppDownloadTarget {
  /// 下载地址；必须是 http/https。
  final String url;

  /// 额外的镜像地址（均须 http/https），按声明顺序优先于内置加速镜像尝试。
  ///
  /// 用途：内置公益镜像失效时，运维只需改清单就能给所有客户端换新下载源，
  /// 不必发新版 App。为空表示只用代码内置镜像 + 直连。
  final List<String> mirrors;

  /// 文件的 sha256（小写十六进制）；为空表示下载后不做校验。
  final String sha256;

  /// 文件体积（字节）；未知时为 0。
  final int sizeBytes;

  const AppDownloadTarget({
    required this.url,
    this.mirrors = const [],
    this.sha256 = '',
    this.sizeBytes = 0,
  });

  /// 从 JSON 构造；地址非法时返回 null（该平台的产物被丢弃）。
  static AppDownloadTarget? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || !isSafeDownloadUrl(url)) return null;
    final sha = raw['sha256'];
    final size = raw['sizeBytes'];

    final mirrors = <String>[];
    final rawMirrors = raw['mirrors'];
    if (rawMirrors is List) {
      for (final item in rawMirrors) {
        if (item is String && isSafeDownloadUrl(item)) mirrors.add(item);
      }
    }

    return AppDownloadTarget(
      url: url,
      mirrors: mirrors,
      sha256: sha is String ? sha.toLowerCase() : '',
      sizeBytes: size is int && size > 0 ? size : 0,
    );
  }

  /// 下载地址是否安全：只允许 http/https，拒绝 `file:` / `javascript:` 等。
  ///
  /// 清单来自外网，地址会被直接交给平台层去下载甚至安装，因此必须在这里把住。
  static bool isSafeDownloadUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isAbsolute) return false;
    return uri.scheme == 'https' || uri.scheme == 'http';
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (mirrors.isNotEmpty) 'mirrors': mirrors,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
  };
}

/// 最新的整包版本。
class AppRelease {
  /// 版本号，形如 `5.6.0`。
  final String version;

  /// 清单里显式声明的变更级别；缺省时为 null，由调用方按版本号差值推断。
  final VersionChangeLevel? declaredLevel;

  /// 更新说明（每行一条）。
  final List<String> notes;

  /// 发布时间。
  final DateTime? publishedAt;

  /// 平台标识（`android` / `ios` / `windows` …）→ 下载产物。
  final Map<String, AppDownloadTarget> downloads;

  const AppRelease({
    required this.version,
    this.declaredLevel,
    this.notes = const [],
    this.publishedAt,
    this.downloads = const {},
  });

  /// 从 JSON 构造；版本号非法时返回 null。
  static AppRelease? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    if (version is! String || !VersionUtils.isValid(version)) return null;

    final downloads = <String, AppDownloadTarget>{};
    final rawDownloads = raw['downloads'];
    if (rawDownloads is Map) {
      for (final entry in rawDownloads.entries) {
        final target = AppDownloadTarget.tryFromJson(entry.value);
        if (target != null) downloads[entry.key.toString()] = target;
      }
    }

    return AppRelease(
      version: version,
      declaredLevel: _parseLevel(raw['level']),
      notes: _parseNotes(raw['notes']),
      publishedAt: DateTime.tryParse(raw['publishedAt']?.toString() ?? ''),
      downloads: downloads,
    );
  }

  /// 相对 [current] 的变更级别：清单显式声明优先，否则按版本号差值推断。
  VersionChangeLevel levelAgainst(String current) {
    return declaredLevel ?? VersionUtils.differenceLevel(version, current);
  }

  /// 指定平台是否有可下载的产物。
  bool supportsPlatform(String platform) => downloads.containsKey(platform);

  /// 按 [platform] 挑下载产物，支持 ABI 细分 + 向后兼容回落。
  ///
  /// `downloads` 的 key 是**自由字符串**（`tryFromJson` 不校验枚举），因此可以写
  /// `android-arm64` / `android-armeabi-v7a` 这类 ABI 细分键。但旧版客户端只会
  /// 拿 `'android'` 来查，所以必须同时保留一个泛化的 `android` 键作为兜底 ——
  /// 否则老用户会静默地「查不到更新」（[supportsPlatform] 返回 false，
  /// 决策降级为无更新，且**不报错**）。
  ///
  /// 本方法把这条兼容链显式化：
  /// 1. 先试最具体键 `<platform>-<abi>`（如 `android-arm64`）；
  /// 2. 再试 `<platform>`（如 `android`）。
  /// 返回第一个命中的产物；都没有则 null。
  ///
  /// 匹配**大小写不敏感**：`update.json` 由人手维护，`Android` 与
  /// `Android-ARM64-V8A` 这类大小写偏差不该导致静默失联。
  /// 但优先精确匹配，避免歧义。
  ///
  /// [abi] 为 null / 空时只走第 2 步（i.e. 等价于旧的 `downloads[platform]`）。
  AppDownloadTarget? resolveTarget(String platform, {String? abi}) {
    if (platform.isEmpty) return null;
    final normalizedAbi = abi?.trim().toLowerCase();
    if (normalizedAbi != null && normalizedAbi.isNotEmpty) {
      final specific = _lookup('$platform-$normalizedAbi');
      if (specific != null) return specific;
    }
    return _lookup(platform);
  }

  /// 先精确查 key，未命中再做一次大小写不敏感的查。
  ///
  /// 单独抽出来是因为 [resolveTarget] 有两处查询，逻辑必须一致 ——
  /// 若只在一处做小写化，就会出现「ABI 键能匹配、平台键不能」的不对称 bug。
  AppDownloadTarget? _lookup(String key) {
    final exact = downloads[key];
    if (exact != null) return exact;
    final lowered = key.toLowerCase();
    for (final entry in downloads.entries) {
      if (entry.key.toLowerCase() == lowered) return entry.value;
    }
    return null;
  }

  /// 清单里实际提供产物的所有 key（用于排查「为什么没匹配上」）。
  List<String> get availablePlatformKeys => downloads.keys.toList(growable: false);

  static VersionChangeLevel? _parseLevel(Object? raw) {
    if (raw is VersionChangeLevel) return raw;
    switch (raw?.toString().trim().toLowerCase()) {
      case 'major':
        return VersionChangeLevel.major;
      case 'minor':
        return VersionChangeLevel.minor;
      case 'patch':
        return VersionChangeLevel.patch;
      default:
        return null;
    }
  }

  static List<String> _parseNotes(Object? raw) {
    if (raw is String) {
      return raw
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
    }
    if (raw is List) {
      return raw
          .map((item) => item?.toString().trim() ?? '')
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    if (declaredLevel != null) 'level': declaredLevel!.name,
    'notes': notes,
    if (publishedAt != null) 'publishedAt': publishedAt!.toUtc().toIso8601String(),
    'downloads': downloads.map((key, value) => MapEntry(key, value.toJson())),
  };
}

/// 资源热更新包。
///
/// 用**单调递增的整数构建号**而不是版本号：资源包会一天里重打好几次，
/// 用 `major.minor.patch` 既容易撞号又要点数不等的位数，整数最不容易出错。
class AssetUpdatePackage {
  /// 构建号；必须比本地已应用的大才会更新。
  final int build;

  /// 压缩包地址（zip）。
  final String url;

  /// 额外的镜像地址（均须 http/https），按声明顺序优先于内置加速镜像尝试。
  ///
  /// 与 [AppDownloadTarget.mirrors] 同义：某个分发节点失效时，运维改清单
  /// 就能给所有客户端换新下载源，不必发新版 App。
  final List<String> mirrors;

  /// 压缩包的 sha256（小写十六进制）；为空表示不校验。
  final String sha256;

  /// 压缩包体积（字节）；未知时为 0。
  final int sizeBytes;

  const AssetUpdatePackage({
    required this.build,
    required this.url,
    this.mirrors = const [],
    this.sha256 = '',
    this.sizeBytes = 0,
  });

  /// 从 JSON 构造；构建号或地址非法时返回 null。
  static AssetUpdatePackage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final build = raw['build'];
    final url = raw['url'];
    if (build is! int || build <= 0) return null;
    if (url is! String || !AppDownloadTarget.isSafeDownloadUrl(url)) return null;
    final sha = raw['sha256'];
    final size = raw['sizeBytes'];

    final mirrors = <String>[];
    final rawMirrors = raw['mirrors'];
    if (rawMirrors is List) {
      for (final item in rawMirrors) {
        if (item is String && AppDownloadTarget.isSafeDownloadUrl(item)) {
          mirrors.add(item);
        }
      }
    }

    return AssetUpdatePackage(
      build: build,
      url: url,
      mirrors: mirrors,
      sha256: sha is String ? sha.toLowerCase() : '',
      sizeBytes: size is int && size > 0 ? size : 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'build': build,
    'url': url,
    if (mirrors.isNotEmpty) 'mirrors': mirrors,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
  };
}
