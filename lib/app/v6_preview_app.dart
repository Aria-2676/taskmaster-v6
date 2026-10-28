import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/data/v6_database.dart';
import '../core/extension/extension_hook.dart';
import '../core/extension/extension_slot.dart';
import '../core/plugin/event_journal.dart';
import '../core/plugin/plugin_index.dart';
import '../core/plugin/plugin_installer.dart';
import '../core/plugin/plugin_store.dart';
import '../core/plugin/plugin_manifest.dart';
import '../core/plugin/plugin_storage.dart';
import '../core/updater/providers/app_update_provider.dart';
import '../core/updater/pages/app_update_page.dart';
import '../core/updater/update_channel.dart';
import '../core/updater/widgets/app_update_dialog.dart';
import 'data/plugin_bridge.dart';
import 'pages/plugin_page.dart';
import 'pages/recycle_bin_page.dart';
import 'data/demo_seed.dart';
import 'data/settings_repository.dart';
import 'data/task_repository.dart';
import 'shell/main_shell.dart';
import 'state/field_store.dart';
import 'state/currency_store.dart';
import 'state/home_mode_store.dart';
import 'state/plugin_market_store.dart';
import 'state/task_store.dart';

/// v6 主包外壳。接 v6 数据层（`v6_tasks.db`），可用独立入口启动：
/// ```bash
/// flutter run -t lib/main_v6_preview.dart
/// ```
///
/// [store] 用于测试注入（内存库）；不传则自己打开真实的 sqflite 库。
class V6PreviewApp extends StatefulWidget {
  const V6PreviewApp({
    super.key,
    this.store,
    this.autoSeed = true,
    this.checkUpdate = false,
    this.injectedUpdate,
  });

  final TaskStore? store;

  /// 首次启动（任务表为空）时写入演示数据。**正式版必须传 false** ——
  /// 否则用户装完看到的是一堆"写完 v6 主包的第一屏"。
  final bool autoSeed;

  /// 测试注入的更新器。
  ///
  /// 有它才能在测试里跑通"从「关于」点进版本页"这条路径 —— 那正是 Provider
  /// 层级写错时唯一会红屏的地方（`checkUpdate: true` 会联网，测试不能开）。
  /// 注入进来的实例**不归这个 State dispose**。
  final AppUpdateProvider? injectedUpdate;

  /// 是否在启动后检查更新。
  ///
  /// 默认关：这个壳既当预览入口又当正式入口，而**检查更新会发网络请求**，
  /// 测试里绝不能默默连外网。正式入口显式传 true。
  ///
  /// 不做这件事的后果很实际：新包发出去之后**再也收不到更新** ——
  /// 它没有更新器，等于绝版。
  final bool checkUpdate;

  @override
  State<V6PreviewApp> createState() => _V6PreviewAppState();
}

class _V6PreviewAppState extends State<V6PreviewApp> {
  static const Color _seed = Color(0xFF6750A4);

  TaskStore? _store;
  PluginMarketStore? _market;
  FieldStore? _fields;
  HomeModeStore? _home;
  CurrencyStore? _currency;
  EventJournal? _journal;
  AppUpdateProvider? _update;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.store != null) {
      _store = widget.store;
    } else {
      _openDatabase();
    }
    final injected = widget.injectedUpdate;
    if (injected != null) {
      _update = injected;
    } else if (widget.checkUpdate) {
      _startUpdater();
    }
  }

  /// 版本检查**不阻断启动**：初始化失败或网络不通时安静跳过，
  /// 回到前台还会按间隔重试（见 [AppUpdatePromptHost]）。
  ///
  /// 走本仓库自己的渠道：`update.json` + `v6` 前缀的本地状态。
  /// V5 那条线在另一个仓库（`Aria-2676/note_study`），两边不再有交集。
  void _startUpdater() {
    const channel = UpdateChannel.current;
    final provider = AppUpdateProvider(
      service: channel.createService(),
      settings: channel.settings,
    );
    _update = provider;
    unawaited(provider.initialize().then((_) => provider.checkIfDue()));
  }

  @override
  void dispose() {
    // 插槽是进程内单例，不摘掉会让测试互相污染（上一个用例的余额漏到下一个）
    if (_currency != null) SlotRegistry.instance.unregister(_currency!.pluginId);
    // 只销毁自己造的：注入进来的实例归调用方
    if (widget.injectedUpdate == null) _update?.dispose();
    super.dispose();
  }

  Future<void> _openDatabase() async {
    try {
      final db = await V6Database.open();
      final repo = TaskRepository(db);
      if (widget.autoSeed) {
        await DemoSeed.runIfEmpty(repo);
      }

      final support = await getApplicationSupportDirectory();
      final installer = PluginInstaller(
        db: db,
        rootDir: Directory(p.join(support.path, 'plugins')),
        fetch: _assetFetch,
      );
      // 启动自愈：上次卸载/安装中断留下的残渣在这里清掉
      await installer.reconcile();
      // 内存注册表每次冷启动都是空的，按已装清单把插件表补回来
      await installer.ensureSchemas();

      // 回收站到期清理：没有后台服务，每次启动扫一遍就够了
      final settings = SettingsRepository(db);
      final retentionDays = await settings.getInt(
        SettingsKeys.recycleRetentionDays,
        fallback: SettingsKeys.defaultRetentionDays,
      );
      await repo.purgeRecycleOlderThan(Duration(days: retentionDays));

      // 字段偏好与首页形态：都必须在**第一帧之前**读好，
      // 否则首页会先画内置、再跳成插件，用户看到的是闪一下
      final fields = FieldStore(settings);
      await fields.load();
      final home = HomeModeStore(settings);
      await home.load();

      // 货币：余额镜像 + 顶上徽章的插槽提供者。
      // **注册进 SlotRegistry**，这样主壳的 `_badge` 不用知道货币是怎么来的 ——
      // 插槽体系本来就是给"外壳上的外来数据"准备的。
      final currency = CurrencyStore(settings);
      await currency.load();
      SlotRegistry.instance.register(currency);

      // 事件日志：插件没挂载时收到的事件先落库，等它下次上来补发。
      // **全局只注册一次**，不是每次打开插件都注册 —— 否则同一条事件会写多份。
      final journal = EventJournal(db);
      HookBus.instance.register(journal);

      if (!mounted) return;
      setState(() {
        _store = TaskStore(repo, settings);
        _fields = fields;
        _home = home;
        _currency = currency;
        _journal = journal;
        _market = PluginMarketStore(
          installer: installer,
          indexLoader: _loadIndex,
          // 首版从内置 asset 装包；接远程时只改这一行
          urlFor: (pkg) => Uri(scheme: 'asset', path: pkg.path),
          // 声明了「能写货币」的插件，装上就把自己报成当前货币（余额 0）。
          // 不这样的话用户装完看不到任何变化，得点进去打开一次才有反应 ——
          // 那一步没人告诉他。
          onInstalled: (entry) {
            if (entry.permissions.contains('currency:write')) {
              // 不是无脑 report(0)：卸载时选了「保留数据」的插件重装回来，
              // 余额在它自己的表里还在，写 0 会让顶栏显示一个假的数字。
              unawaited(_currency?.ensureProvider(entry.id));
            }
          },
          // 卸载会留下指向它的持久化状态（谁是首页、谁是货币）。
          // 不通知的话「首页模式」页会一个都不选中，货币则会挂着一个空壳。
          onUninstalled: (pluginId) {
            unawaited(_home?.onPluginUninstalled(pluginId));
            unawaited(_currency?.onPluginUninstalled(pluginId));
          },
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// 回收站页面。`MainShell` 没有仓储层，由应用层在这里组装。
  ///
  /// `marketStore` 为 null 时（测试注入 store）返回 null —— 入口会提示"未接入"。
  WidgetBuilder? _recyclePageBuilder(TaskStore store) {
    final market = _market;
    if (market == null) return null;
    final repo = TaskRepository(market.installer.db);
    return (_) => RecycleBinPage(
          repository: repo,
          retentionDays: store.retentionDays,
          // 恢复之后首页要能立刻看到
          onChanged: store.load,
        );
  }

  /// 把一个已装插件变成可打开的页面：入口路径、权限都取自包内 `plugin.json`。
  Future<PluginLaunchSpec> _launchPlugin(InstalledPlugin plugin) async {
    // 所有依赖都从 `_market.installer` 取，不另存字段。
    // 另存的那份在**热重载**后会变成 null（State 复用、新字段没被赋值），
    // 于是点开插件就抛 `Null check operator used on a null value` —— 一个
    // 只在开发期出现、却极难对上原因的假崩溃。
    final market = _market;
    if (market == null) {
      throw StateError('插件运行环境尚未就绪');
    }
    final installer = market.installer;
    final manifest = await installer.manifestOf(plugin);
    final directory = await installer.directoryOf(plugin);
    final db = installer.db;

    return PluginLaunchSpec(
      title: manifest.name,
      entryPath: p.join(directory, manifest.entry),
      bridge: PluginBridge(
        pluginId: plugin.pluginId,
        // 用包内 plugin.json 的版本，不是安装记录里那份：插件页显示的是
        // "正在运行的这份代码"的版本。升级后目录换了，manifest 跟着换。
        version: manifest.version,
        permissions: manifest.permissions,
        tasks: TaskRepository(db),
        settings: SettingsRepository(db),
        contract: PluginContract.current,
        hooks: manifest.hooks,
        journal: _journal,
        // 插件自己的表。没声明 storage 的插件拿到 null，
        // 调 db.* 会得到 no_storage —— 而不是静默什么都不做。
        data: manifest.storage.isEmpty
            ? null
            : PluginDataStore(
                db: db,
                pluginId: plugin.pluginId,
                spec: manifest.storage,
              ),
        // 插件写完要通知主包重读：否则"插件里加了任务、退出插件首页还是旧的"。
        // 用闭包读 `_store`，避免热重载后拿到已失效的实例。
        onChanged: () => _store?.load(),
        // 宿主没接货币时传 null，bridge 会回 bad_params 而不是静默成功
        currency: _currency,
      ),
      hooks: manifest.hooks,
    );
  }

  static Future<PluginIndex> _loadIndex() async {
    final text = await rootBundle.loadString('assets/plugins/index.json');
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const PluginFormatException('index.json 顶层必须是对象');
    }
    return PluginIndex.parse(Map<String, Object?>.from(decoded));
  }

  static Future<void> _assetFetch({
    required Uri url,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) async {
    final data = await rootBundle.load(url.path);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(destPath).writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
        useMaterial3: true,
      );

  /// Provider 必须包在 **MaterialApp 外面**。
  ///
  /// 放在 `home` 里会漏掉一个致命场景：`Navigator.push` 出来的路由挂在 Navigator
  /// 下，而 Navigator 在 MaterialApp 内 —— 那些页面看不到 home 子树里的 Provider。
  /// 表现是从「关于」点进版本页直接 `ProviderNotFoundException` 红屏。
  Widget _withUpdateProvider(Widget child) {
    final provider = _update;
    if (provider == null) return child;
    return ChangeNotifierProvider<AppUpdateProvider>.value(
      value: provider,
      child: child,
    );
  }

  /// 弹窗宿主必须放在 **MaterialApp 里面**，因为它要 `showDialog`（需要 Navigator）。
  ///
  /// 和上面那条不是矛盾：Provider 要给所有路由用，所以在外层；宿主只需要在
  /// 首页盯着，所以在内层。
  Widget _withUpdatePrompt(Widget child) {
    if (_update == null) return child;
    return AppUpdatePromptHost(child: child);
  }

  @override
  Widget build(BuildContext context) {
    return _withUpdateProvider(
      MaterialApp(
      title: '任务管家',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      // 不加这三行，Material 自带的日期选择器、复制粘贴菜单全是英文。
      // v5 的 main.dart 早就配了，v6 预览壳是漏的。
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: _withUpdatePrompt(_buildHome()),
      ),
    );
  }

  Widget _buildHome() {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('数据库打开失败：$_error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final store = _store;
    if (store == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // 测试注入 store 时没有插件基础设施，此时市场入口只提示未接入
    return MainShell(
      store: store,
      marketStore: _market,
      pluginLauncher: _launchPlugin,
      recyclePageBuilder: _recyclePageBuilder(store),
      // 没有更新器时不给入口，避免点进去 context.read 找不到 Provider
      aboutPageBuilder: _update == null
          ? null
          : (_) => const AppUpdatePage(title: '关于'),
      fieldStore: _fields,
      homeStore: _home,
      currencyStore: _currency,
    );
  }
}
