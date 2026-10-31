import '../extension/extension_hook.dart';
import '../extension/extension_slot.dart';
import 'plugin_storage.dart';

/// 插件包格式错误。**所有解析失败都抛它**，调用方只需处理这一种异常。
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

class PluginFormatException implements Exception {
  const PluginFormatException(this.message);

  final String message;

  @override
  String toString() => 'PluginFormatException: $message';
}

/// 契约版本。宿主只接受落在 [min, current] 区间内的插件。
///
/// 为什么用契约版本而不是 app 版本：兼容性只取决于"扩展点接口有没有变"。
/// app 从 6.0 升到 6.3，只要契约没动，已装的插件一个都不用重发。
class PluginContract {
  const PluginContract._();

  /// 当前宿主实现的契约版本。**改扩展点接口时必须 +1**。
  static const int current = 1;

  /// 还能接受的最老契约。降它等于放弃对老插件的兼容。
  static const int min = 1;

  static bool accepts(int contract) => contract >= min && contract <= current;
}

/// 可下载的包描述（索引里的一项，也是安装时校验的依据）。
class PluginPackage {
  const PluginPackage({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
  });

  factory PluginPackage.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    final sha256 = json['sha256'];
    final size = json['sizeBytes'];

    if (path is! String || path.isEmpty) {
      throw const PluginFormatException('package.path 缺失');
    }
    // 包路径只允许相对路径：绝对路径和 .. 都会让下载器写到插件目录外面
    if (path.startsWith('/') || path.contains('..') || path.contains('\\')) {
      throw PluginFormatException('package.path 必须是安全的相对路径：$path');
    }
    if (sha256 is! String || !_sha256Pattern.hasMatch(sha256)) {
      throw const PluginFormatException('package.sha256 必须是 64 位小写十六进制');
    }
    if (size is! int || size <= 0) {
      throw const PluginFormatException('package.sizeBytes 必须是正整数');
    }

    return PluginPackage(path: path, sha256: sha256, sizeBytes: size);
  }

  /// 相对索引根目录的路径
  final String path;

  /// 小写十六进制
  final String sha256;

  final int sizeBytes;
}

/// 插件声明的「可以当首页模式」。
///
/// 声明它只做两件事，**不是准入**：
/// 1. 这个模式默认出现在顶栏的快捷切换里（没声明的是默认收起，用户可自己打开）；
/// 2. 给模式一个短名字和一句说明 —— 顶栏要塞得下，插件名往往太长
///    （插件叫「周计划」，模式叫「计划模式」）。
///
/// 为什么不拿它当准入：能当首页本身没什么危险，插件整页换的只是内容区，
/// 底栏、侧边栏、`+` 都不动，随时能切回内置。拦掉反而让用户少了一种玩法。
class PluginHomeSpec {
  const PluginHomeSpec({this.label, this.hint, this.order = 100});

  /// 只写 `"home": true` 时的形态：默认开启，名字沿用插件名
  static const PluginHomeSpec bare = PluginHomeSpec();

  /// 顶栏标题与快捷切换里显示的名字
  final String? label;

  /// 一句人话，替代自动生成的「插件整页 · v1.0.0」
  final String? hint;

  /// 列表顺序（小的在前）。同值按安装顺序。
  final int order;

  /// 解析失败一律当"没声明"：认不出来的字段不该让插件装不上。
  static PluginHomeSpec? tryParse(Object? raw) {
    if (raw == null || raw == false) return null;
    if (raw == true) return bare;
    if (raw is! Map) return null;

    String? text(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return PluginHomeSpec(
      label: text(raw['label']),
      hint: text(raw['hint']),
      order: raw['order'] is int ? raw['order']! as int : 100,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (label != null) 'label': label,
        if (hint != null) 'hint': hint,
        'order': order,
      };

  /// 按值比较：索引里那份是从 `plugin.json` 复制的，两边必须逐字段相同
  /// （`asset_index_test` 就是靠它守住"索引和包内别对不上"）。
  @override
  bool operator ==(Object other) =>
      other is PluginHomeSpec &&
      other.label == label &&
      other.hint == hint &&
      other.order == order;

  @override
  int get hashCode => Object.hash(label, hint, order);
}

/// `plugin.json` —— 包内清单。
///
/// 校验刻意严格：`id` 会进入目录名和插件表前缀，`entry` 会拼进 WebView 的
/// 本地 URL。这两处一旦被注入了 `..` 或绝对路径，后果不是"难看"而是越界读写。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.contract,
    required this.entry,
    this.description,
    this.icon,
    this.slots = const <SlotId>{},
    this.hooks = const <HookId>{},
    this.permissions = const <String>{},
    this.home,
    this.storage = const PluginStorageSpec(version: 1, tables: <PluginTableDecl>[]),
  });

  factory PluginManifest.parse(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final version = json['version'];
    final contract = json['contract'];
    final entry = json['entry'];

    if (id is! String || !idPattern.hasMatch(id)) {
      throw PluginFormatException('id 非法（只允许小写字母/数字/下划线，2~32 位）：$id');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const PluginFormatException('name 不能为空');
    }
    if (version is! String || !versionPattern.hasMatch(version)) {
      throw PluginFormatException('version 必须是 x.y.z：$version');
    }
    if (contract is! int) {
      throw const PluginFormatException('contract 必须是整数');
    }
    if (!PluginContract.accepts(contract)) {
      throw PluginFormatException(
        '契约版本 $contract 不受支持（宿主支持 ${PluginContract.min}~${PluginContract.current}）',
      );
    }
    if (entry is! String || !_isSafeEntry(entry)) {
      throw PluginFormatException('entry 必须是包内相对 .html 路径：$entry');
    }

    return PluginManifest(
      id: id,
      name: name.trim(),
      version: version,
      contract: contract,
      entry: entry,
      description: json['description'] is String ? json['description']! as String : null,
      icon: json['icon'] is String ? json['icon']! as String : null,
      slots: _parseSlots(json['slots']),
      hooks: _parseHooks(json['hooks']),
      permissions: _parsePermissions(json['permissions']),
      home: PluginHomeSpec.tryParse(json['home']),
      storage: PluginStorageSpec.fromJson(json['storage']),
    );
  }

  /// `[a-z0-9_]`，2~32 位。会被用作 `plg_<id>_` 表前缀与目录名。
  static final RegExp idPattern = RegExp(r'^[a-z][a-z0-9_]{1,31}$');

  static final RegExp versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

  final String id;
  final String name;
  final String version;
  final int contract;

  /// 包内入口 HTML（相对 zip 根）
  final String entry;

  final String? description;

  /// Material 图标名。**插件只给名字，主包决定怎么画**。
  final String? icon;

  /// 该插件要参与的数据插槽
  final Set<SlotId> slots;

  /// 该插件要订阅的事件钩子。
  ///
  /// **必须声明才会收到**：宿主只往声明了的钩子上推。这不是权限（拿不到数据），
  /// 而是"别给不需要的插件推它处理不了的事件"—— 省得插件侧写一堆空分支。
  final Set<HookId> hooks;

  /// 数据权限。**不声明就拿不到数据** —— 默认空集，最小权限。
  final Set<String> permissions;

  /// 可当首页模式的声明。null = 没声明：仍可当首页，但默认不在快捷切换里。
  final PluginHomeSpec? home;

  /// 插件自己的表声明。空 = 不存自己的数据（只读写主包任务的那种插件）。
  ///
  /// 表会建成 `plg_<id>_<name>`；插件**永远拿不到表名之外的自由** ——
  /// 不能指向主包表，也不能执行任意 SQL（见 `PluginDataStore`）。
  final PluginStorageSpec storage;

  /// 当前宿主认识的权限。声明了不认识的一律忽略（向前兼容）。
  ///
  /// 读、写、删三条分开：老插件只声明 `task:read` 就永远拿不到写能力，
  /// 新插件想写必须显式加上 `task:write`，删还要再加 `task:delete`。
  static const Set<String> knownPermissions = <String>{
    'task:read',
    'task:write',
    'task:delete',
    'tag:read',
    'currency:read',
    'currency:write',
  };

  bool has(String permission) => permissions.contains(permission);

  static bool _isSafeEntry(String entry) {
    if (!entry.endsWith('.html')) return false;
    if (entry.startsWith('/') || entry.contains('\\')) return false;
    // 允许 `a/b.html`，但不允许跳出包目录
    final segments = entry.split('/');
    return !segments.any((s) => s.isEmpty || s == '..' || s == '.');
  }

  static Set<String> _parsePermissions(Object? raw) {
    if (raw is! List) return const <String>{};
    return <String>{
      for (final item in raw)
        if (item is String && knownPermissions.contains(item)) item,
    };
  }

  /// 不认识的插槽 id 直接忽略：老宿主遇到新插件的插槽，应该少画一块，
  /// 而不是拒绝安装整个插件。
  static Set<SlotId> _parseSlots(Object? raw) {
    if (raw is! List) return const <SlotId>{};
    final known = <String, SlotId>{for (final s in SlotId.values) s.id: s};
    return <SlotId>{
      for (final item in raw)
        if (item is String && known.containsKey(item)) known[item]!,
    };
  }

  /// 同理：不认识的钩子忽略。插件声明了新钩子、宿主还不支持 ——
  /// 插件少收一类事件而已，不该装不上。
  static Set<HookId> _parseHooks(Object? raw) {
    if (raw is! List) return const <HookId>{};
    final known = <String, HookId>{for (final h in HookId.values) h.id: h};
    return <HookId>{
      for (final item in raw)
        if (item is String && known.containsKey(item)) known[item]!,
    };
  }
}
