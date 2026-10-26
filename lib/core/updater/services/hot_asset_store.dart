import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

/// 热更资源（`hot_assets/`）的统一读取入口。
///
/// 背景：`AppAssetApplier` 负责把资源包**写入** `hot_assets/`，但资源要被业务
/// 真正用上，还需要一个统一的**读**入口。本类就是那一半，且刻意放在 `core/`
/// 层——因为铁律规定 `core/` 不能 import `modules/*`，而读取逻辑如果写在某个
/// 业务模块里，其他模块就没法复用（要么互相 import，要么各抄一份）。
///
/// 定位规则：**同名文件以热更目录为准，缺失时回落包内 `assets/`**。这样业务侧
/// 的改造永远是「先问 store 要，拿不到再用自带的」，不会因为没有热更包而坏掉。
///
/// 缓存策略：目录本身**只解析一次**（首次调用时异步查盘），此后同步查询。
/// 这是必要的——UI 的 `build()` 可能每帧调用 [localFileFor]，若每次都
/// `await` 查盘会造成明显掉帧；[invalidate] 供资源包落地后主动失效。
class HotAssetStore {
  /// 公开的无参构造：允许测试建独立实例，互不污染全局单例的缓存。
  ///
  /// 生产代码请用 [instance]——每处 `HotAssetStore()` 都会自带一份查盘缓存，
  /// 既浪费 IO，也让 [invalidate] 失效不彻底。
  HotAssetStore();

  static HotAssetStore _instance = HotAssetStore();

  /// 全局实例。
  static HotAssetStore get instance => _instance;

  /// 仅供测试：替换全局实例（传 null 恢复默认单例）。
  ///
  /// 生产代码不要调用——它会让已有引用指向旧实例，属于典型的状态泄漏。
  static void debugOverrideInstance(HotAssetStore? store) {
    _instance = store ?? HotAssetStore();
  }

  /// 仅在测试中设置：指定 hot_assets 根目录，跳过 path_provider。
  String? _injectedRoot;

  /// 已解析的根目录；null 表示「尚未解析」。
  String? _cachedRoot;

  /// 是否已经解析过（无论成功与否）。避免目录不存在时反复查盘。
  bool _resolved = false;

  /// 热更目录下的相对路径 → 实际存在的文件；null 表示确认不存在。
  final Map<String, File?> _fileCache = {};

  /// 指定根目录（测试用）。返回自身以便链式调用。
  HotAssetStore withRootForTest(String? rootDir) {
    _injectedRoot = rootDir;
    _cachedRoot = null;
    _resolved = false;
    _fileCache.clear();
    return this;
  }

  /// 丢弃全部缓存，下次读取重新查盘。
  ///
  /// 资源包应用成功后必须调用——否则旧文件被记住「不存在」，新素材要重启才生效。
  void invalidate() {
    _cachedRoot = null;
    _resolved = false;
    _fileCache.clear();
  }

  /// 热更资源根目录的绝对路径；目录不存在时返回 null。
  Future<String?> rootDirectory() async {
    if (_resolved) return _cachedRoot;
    _resolved = true;

    final injected = _injectedRoot;
    if (injected != null) {
      _cachedRoot = await Directory(injected).exists() ? injected : null;
      return _cachedRoot;
    }

    try {
      final base = await getApplicationSupportDirectory();
      final dir = p.join(base.path, 'hot_assets');
      _cachedRoot = await Directory(dir).exists() ? dir : null;
    } catch (error, stack) {
      // 平台通道不可用（未初始化绑定 / 桌面端缺插件）：视作「没有热更资源」，
      // 让调用方安静回落到包内素材，而不是把异常抛进 UI。
      AppLogger.warn(
        'HotAssetStore',
        '定位 hot_assets 目录失败，按「无热更资源」处理',
        error,
        stack,
      );
      _cachedRoot = null;
    }
    return _cachedRoot;
  }

  /// 解析热更目录下某个相对路径的绝对路径；越界或不存在时返回 null。
  ///
  /// [relativePath] 形如 `games/icons/2048.png`。以 `/` 开头、含 `..`、
  /// 或命中 Windows 盘符的一律拒绝——热更包来自外网，路径必须当成不可信输入。
  Future<String?> resolvePath(String relativePath) async {
    final file = await localFileFor(relativePath);
    return file?.path;
  }

  /// 同 [resolvePath]，但返回 [File]；不存在时返回 null。
  ///
  /// 结果按路径缓存，因此可以放在 `build()` 里同步使用（首次仍是 async）。
  Future<File?> localFileFor(String relativePath) async {
    final safe = _sanitize(relativePath);
    if (safe == null) return null;

    if (_fileCache.containsKey(safe)) return _fileCache[safe];

    final root = await rootDirectory();
    if (root == null) {
      _fileCache[safe] = null;
      return null;
    }

    final candidate = p.normalize(p.join(root, safe));
    // 第二道防线：即使 [_sanitize] 将来被人改松（比如为支持某个新语法而放行 `.`），
    // 这里再按「相对 root 的相对路径不得以 .. 开头」复核一次。与
    // `GameAssetServer._resolveTarget` 保持同一套纵深防御策略。
    final relative = p.relative(candidate, from: root);
    if (relative.startsWith('..') || p.isAbsolute(relative)) {
      AppLogger.warn('HotAssetStore', '拒绝越界的热更路径: $relativePath');
      _fileCache[safe] = null;
      return null;
    }

    File? found;
    try {
      if (await File(candidate).exists()) found = File(candidate);
    } catch (error) {
      AppLogger.warn('HotAssetStore', '检查热更文件失败: $safe', error);
    }
    _fileCache[safe] = found;
    return found;
  }

  /// 该相对路径是否有可用的热更文件。
  Future<bool> has(String relativePath) async =>
      await localFileFor(relativePath) != null;

  /// 读取文本内容（UTF-8）；不存在或读取失败时返回 null。
  Future<String?> readAsString(String relativePath) async {
    final file = await localFileFor(relativePath);
    if (file == null) return null;
    try {
      return await file.readAsString();
    } catch (error, stack) {
      AppLogger.warn('HotAssetStore', '读取热更文本失败: $relativePath', error, stack);
      return null;
    }
  }

  /// 读取二进制内容；不存在或读取失败时返回 null。
  Future<List<int>?> readAsBytes(String relativePath) async {
    final file = await localFileFor(relativePath);
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (error, stack) {
      AppLogger.warn('HotAssetStore', '读取热更文件失败: $relativePath', error, stack);
      return null;
    }
  }

  /// 解析 JSON；不存在、读取失败或解析失败时返回 null。
  ///
  /// 这里**不抛异常**：热更内容是外网产物，一个手滑的逗号不该让启动崩掉。
  /// 调用方拿到 null 就沿用内置默认值，属于 fail-soft。
  Future<Object?> readAsJson(String relativePath) async {
    final text = await readAsString(relativePath);
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (error, stack) {
      AppLogger.warn(
        'HotAssetStore',
        '热更 JSON 解析失败: $relativePath',
        error,
        stack,
      );
      return null;
    }
  }

  /// 校验并规范化相对路径；不合法时返回 null。
  ///
  /// 与 `GamePathUtils.normalizeRelative` 同源思路，但刻意不 import 它——
  /// 那是 `modules/games` 的东西，`core` 反向依赖会破坏依赖方向。
  static String? _sanitize(String raw) {
    final trimmed = raw.trim().replaceAll('\\', '/');
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/')) return null;
    if (_windowsDrive.hasMatch(trimmed)) return null;
    final segments = trimmed.split('/');
    if (segments.any((s) => s == '..' || s.isEmpty)) return null;
    return segments.join('/');
  }

  static final RegExp _windowsDrive = RegExp(r'^[a-zA-Z]:');
}
