import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/extension/extension_slot.dart';
import '../models/calendar_strip_style.dart';
import '../models/task.dart';
import '../pages/v6_home_page.dart';
import '../../core/plugin/plugin_store.dart';
import '../pages/field_manager_page.dart';
import '../pages/home_mode_page.dart';
import '../pages/plugin_market_page.dart';
import '../../core/config/legacy_v5_link.dart';
import '../../core/updater/providers/app_update_provider.dart';
import '../../core/updater/services/app_update_launcher.dart';
import '../pages/settings_page.dart';
import '../pages/plugin_page.dart';
import '../pages/tag_manager_page.dart';
import '../pages/task_editor_page.dart';
import '../widgets/mode_switcher.dart';
import 'destinations.dart';
import '../state/currency_store.dart';
import '../state/field_store.dart';
import '../state/home_mode_store.dart';
import '../state/pending_delete_guard.dart';
import '../state/plugin_market_store.dart';
import '../state/task_store.dart';
import 'profile_stub_page.dart';
import 'side_nav.dart';

/// v6 主包外壳：顶栏（日期）+ 半屏侧边栏 + 首页/我的 + 底栏（首页 · 添加 · 我的）。
///
/// 数据来自 [TaskStore]；四个显示位从 `SlotRegistry` 取插件数据，
/// 没有插件时全部落到主包默认实现（顶栏默认格式、无徽章、无标记、无附加行）。
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.store,
    this.marketStore,
    this.pluginLauncher,
    this.recyclePageBuilder,
    this.aboutPageBuilder,
    this.backupPageBuilder,
    this.fieldStore,
    this.homeStore,
    this.currencyStore,
  });

  final TaskStore store;

  /// 为 null 时"插件市场"入口只提示未接入（测试里不需要整套插件基础设施）
  final PluginMarketStore? marketStore;

  /// 打开已装插件时调用，由应用层提供数据源（`MainShell` 不碰数据库）
  final Future<PluginLaunchSpec> Function(InstalledPlugin plugin)? pluginLauncher;

  /// 回收站页面的构造器。同样由应用层提供 —— `MainShell` 没有仓储层。
  final WidgetBuilder? recyclePageBuilder;

  /// 「关于」页的构造器。为 null 时（没有更新器，比如测试/预览）只提示未接入。
  ///
  /// 关于页同时承担"手动检查更新"的职责：自动检查被跳过、被关掉之后，
  /// 用户需要一个能自己按一下的地方，否则就彻底没有反悔的路径。
  final WidgetBuilder? aboutPageBuilder;

  /// 备份与还原页。为 null 时设置页**不显示「数据」组** ——
  /// 不放灰的占位项，点不动的入口只会让人以为 App 坏了。
  final WidgetBuilder? backupPageBuilder;

  /// 字段偏好（编辑页画哪些字段）
  final FieldStore? fieldStore;

  /// 首页形态 + 熔断。为 null 时永远用内置首页。
  final HomeModeStore? homeStore;

  /// 当前货币（余额镜像 + 提供者）。为 null 时顶栏不显示徽章。
  final CurrencyStore? currencyStore;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const List<String> _weekday = <String>['一', '二', '三', '四', '五', '六', '日'];

  DateTime _selected = DateTime.now();
  int _tab = 0;
  int _resetSignal = 0;
  CalendarStripStyle _calendarStyle = CalendarStripStyle.scroll;

  // ---- 可换首页 ----
  //
  // 三条保险都在这里：2 秒首帧超时、失败计数（在 HomeModeStore 里）、
  // 以及"本次启动不再重试"的开关 —— 没有最后这条，失败后每来一次通知
  // 就会重新加载一次，用户看到的是首页不停闪。
  PluginLaunchSpec? _homeSpec;
  String? _syncedHomeId;
  bool _homeDisabledForSession = false;
  Timer? _homeWatchdog;

  /// 用户在弹窗里勾了"以后不再提醒"，但**还没落库**。
  ///
  /// 必须等删除动作完成后再写：`confirmDismiss` 期间一旦调用
  /// `setConfirmBeforeDelete`（它会 notifyListeners），整棵树会在 Dismissible
  /// 正等待结果时重建，真机上会把卡片卡在"完全滑出"的位置 —— 动画不继续、
  /// `onDismissed` 不触发，于是任务既没删掉、也没弹回去。
  bool _pendingDisableConfirm = false;

  /// 已确认删除、正在等 Dismissible 播完动画的任务。
  /// 动画没走完时由它兜底，见 [PendingDeleteGuard]。
  late final PendingDeleteGuard _deletes = PendingDeleteGuard(
    onExpired: (task) {
      // 出现这行说明 Dismissible 的动画没有回调 onDismissed（就是历史上那个 bug）
      debugPrint('[delete] onDismissed 未触发，走兜底删除 taskId=${task.id}');
      _applyDelete(task);
    },
  );

  TaskStore get _store => widget.store;

  String get _defaultDateLabel =>
      '${_selected.month}月${_selected.day}日 周${_weekday[_selected.weekday - 1]}';

  /// 顶栏日期：插件可以换成农历、年月日等任意文本；没插件就用默认格式。
  String get _dateLabel {
    final slot = SlotRegistry.instance.resolve(
      SlotId.headerDate,
      context: <String, Object?>{'date': TaskDate.dayKey(_selected)},
    );
    return slot is HeaderDateValue ? slot.text : _defaultDateLabel;
  }

  Map<DateTime, String>? get _calendarMarks {
    final slot = SlotRegistry.instance.resolve(SlotId.calendarMarks);
    return slot is CalendarMarksValue ? slot.marks : null;
  }

  String? _extraLineFor(Task task) {
    final slot = SlotRegistry.instance.resolve(
      SlotId.taskCardExtra,
      context: <String, Object?>{'taskId': task.id},
    );
    return slot is TaskCardExtraValue ? slot.text : null;
  }

  /// 侧边栏要同时反映任务与已装插件的变化。
  ///
  /// 也听 [HomeModeStore]：顶栏标题写着"现在是哪个模式"，切换后必须立刻跟着变 ——
  /// 否则用户切了模式，标题还挂着插件名，看着像没切成功。
  late final Listenable _listenable = Listenable.merge(<Listenable>[
    _store,
    if (widget.marketStore != null) widget.marketStore!,
    if (widget.homeStore != null) widget.homeStore!,
    if (widget.currencyStore != null) widget.currencyStore!,
  ]);

  @override
  void initState() {
    super.initState();
    _store.load(_selected);
    widget.marketStore?.refresh();
    widget.homeStore?.addListener(_onHomeModeChanged);
    // **也要听市场的加载完成**：已装列表是异步读库的，initState 里还是空的。
    // 只听 homeStore 的话，冷启动时 _syncHome 找不到插件就直接返回，
    // 表现是"设了插件首页，第一次生效，重启就回内置了"。
    widget.marketStore?.addListener(_onHomeModeChanged);
    _syncHome();
  }

  // ---- 可换首页 ----

  void _onHomeModeChanged() => _syncHome();

  /// 把「首页是谁」变成「要嵌哪个 Spec」。
  ///
  /// 幂等：同一个插件不会因为一次 notifyListeners 就重新加载 WebView。
  /// 卸载、切换模式、失败降级都会走到这里。
  Future<void> _syncHome() async {
    final home = widget.homeStore;
    if (home == null) return;

    final id = home.mode.pluginId;
    if (id == null || _homeDisabledForSession) {
      debugPrint('[home] 内置（id=$id disabled=$_homeDisabledForSession）');
      _syncedHomeId = null;
      if (_homeSpec != null && mounted) setState(() => _homeSpec = null);
      return;
    }

    // 已经在跑同一个了，不要重建（WebView 重建 = 白屏 + 丢状态）
    if (id == _syncedHomeId && _homeSpec != null) return;

    final launcher = widget.pluginLauncher;
    final market = widget.marketStore;
    if (launcher == null || market == null) return;

    // 只在**启用中**的里面找：停用等于这个位置没人了，和卸载一样回内置。
    InstalledPlugin? plugin;
    for (final item in market.active) {
      if (item.pluginId == id) {
        plugin = item;
        break;
      }
    }
    if (plugin == null) {
      // 装了又卸了：直接回内置，不用报错
      debugPrint('[home] 插件 $id 未出现在已装列表（${market.installed.length} 个）');
      _syncedHomeId = null;
      if (_homeSpec != null && mounted) setState(() => _homeSpec = null);
      return;
    }

    try {
      final spec = await launcher(plugin);
      if (!mounted) return;
      debugPrint('[home] 载入插件首页 $id');
      _syncedHomeId = id;
      setState(() => _homeSpec = spec);
      _startHomeWatchdog(id);
    } catch (error, stack) {
      debugPrint('[home] 插件首页启动失败：$error\n$stack');
      await _homeFailure('「${_pluginName(id)}」打不开，已回内置首页');
    }
  }

  void _startHomeWatchdog(String id) {
    _homeWatchdog?.cancel();
    _homeWatchdog = Timer(const Duration(seconds: 2), () {
      if (!mounted || _homeSpec == null) return;
      _homeFailure('「${_pluginName(id)}」加载超时，已回内置首页');
    });
  }

  /// 首页插件挂了。**先让内置首页接上**，再谈计数。
  Future<void> _homeFailure(String message) async {
    _homeWatchdog?.cancel();
    // 先锁住本次会话：reportFailure 会 notifyListeners，
    // 不先锁就会立刻重新加载，形成失败重试的死循环
    _homeDisabledForSession = true;

    if (mounted) setState(() => _homeSpec = null);
    await widget.homeStore?.reportFailure();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  void _onHomeLoaded(String url) {
    // 已经判定失败就别再洗白：加载失败时 WebView 仍然会回调 onPageFinished
    // （错误页也算"加载完成"），不挡住的话失败计数会被自己清零，
    // "连续两次失败自动降级"就永远不会发生。
    if (_homeDisabledForSession) return;
    _homeWatchdog?.cancel();
    // 首页真的画出来了，才算这次会话成功 —— 失败计数在这里清零
    widget.homeStore?.markRendered();
  }

  String _pluginName(String id) =>
      widget.marketStore?.index.findById(id)?.name ?? id;

  /// 插件首页。null = 用内置首页。
  Widget? _pluginHome() {
    final spec = _homeSpec;
    if (spec != null) {
      return PluginView(
        entryPath: spec.entryPath,
        bridge: spec.bridge,
        hooks: spec.hooks,
        onLoaded: _onHomeLoaded,
        onError: (error) => _homeFailure('首页插件报错：$error'),
      );
    }

    // **只有"本来就要用内置首页"才算渲染成功。**
    // 用户选的是插件首页时，内置首页只是加载期间/失败后的临时替补 ——
    // 把它算成功会立刻把失败计数清零，那样"连续两次失败就降级"永远触发不了。
    final wantedBuiltin = widget.homeStore?.mode.isBuiltin ?? true;
    if (wantedBuiltin && !_homeDisabledForSession) _markBuiltinRendered();
    return null;
  }

  bool _builtinMarked = false;

  /// 内置首页也算"渲染成功" —— 否则上次是插件首页崩了、这次降级到内置，
  /// 标记还停在"未完成"，下次启动又会多记一次失败。
  void _markBuiltinRendered() {
    if (_builtinMarked) return;
    _builtinMarked = true;
    // build 期间不能 notifyListeners，挪到帧后
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.homeStore?.markRendered();
    });
  }

  @override
  void dispose() {
    widget.homeStore?.removeListener(_onHomeModeChanged);
    widget.marketStore?.removeListener(_onHomeModeChanged);
    _homeWatchdog?.cancel();
    _deletes.dispose();
    super.dispose();
  }

  /// 打开已装插件。入口路径、权限都从包内 `plugin.json` 读，
  /// 数据源由应用层通过 [pluginLauncher] 注入。
  Future<void> _openPlugin(InstalledPlugin plugin) async {
    final launcher = widget.pluginLauncher;
    final navigator = Navigator.of(context);
    // 兜底：入口已经被过滤掉了，还能走到这里说明是从别处（首页、旧调用点）
    // 传进来的。停用的插件不该能打开 —— 否则"停用"只挡住了一处入口。
    if (!plugin.enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('「${_pluginName(plugin.pluginId)}」已停用，先在插件市场里启用'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (launcher == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('插件运行环境未接入'), duration: Duration(seconds: 1)),
      );
      return;
    }

    try {
      final spec = await launcher(plugin);
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PluginPage(
            title: spec.title,
            entryPath: spec.entryPath,
            bridge: spec.bridge,
            hooks: spec.hooks,
          ),
        ),
      );
    } catch (error, stack) {
      // 先打完整栈：插件打不开时，界面上只能显示一行字，
      // 真正定位问题靠的还是这里（以前这里只 showSnackBar，栈被吞掉了）
      debugPrint('[plugin] 打开失败：$error\n$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插件打不开：$error'), duration: const Duration(seconds: 4)),
      );
    }
  }

  /// 改保留时长。改短可能立刻清掉一些条目，得告诉用户清了几条 ——
  /// 否则"我刚改了个设置，回收站里少了几条"会显得像 bug。
  Future<void> _setRetentionDays(int days) async {
    // 改短才可能立刻删东西；改长只是延后，不用问。
    if (days < _store.retentionDays) {
      final wouldPurge = await _store.countRecycleExpiringWith(days);
      if (!mounted) return;

      if (wouldPurge > 0) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('缩短保留时长', style: TextStyle(fontSize: 16)),
            content: Text(
              '回收站里有 $wouldPurge 条已经超过 $days 天，继续会立刻彻底删除，无法恢复。',
              style: const TextStyle(fontSize: 13.5),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (confirmed != true) {
          // 取消后 store 没变、也不会 notify，分段按钮的选中态会停在"新值"上，
          // 所以手动 rebuild 一次把它拉回来
          setState(() {});
          return;
        }
      }
    }

    final purged = await _store.setRetentionDays(days);
    if (!mounted || purged == 0) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已按新的保留时长清理 $purged 条'),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// 打开编辑。形态（弹层 / 全屏）由设置决定，这里不关心。
  /// 删除动作仍由壳层执行（确认框、回收站开关都在这里），
  /// 编辑页只负责"点一下删除，然后告诉我删没删掉"。
  Future<void> _openEditor(Task task) async {
    final outcome = await showTaskEditor(
      context,
      store: _store,
      fields: widget.fieldStore,
      task: task,
      onDelete: () => _deleteFromEditor(task),
    );
    if (!mounted || outcome == null) return;

    final text = switch (outcome) {
      TaskEditOutcome.saved => '已保存',
      TaskEditOutcome.deleted => _store.recycleBinEnabled
          ? '「${task.title}」已移入回收站'
          : '「${task.title}」已删除',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  /// 编辑页里点删除。返回 true 表示真的删掉了（编辑页据此关掉自己）。
  Future<bool> _deleteFromEditor(Task task) async {
    var disableConfirm = false;
    if (_store.confirmBeforeDelete) {
      final answer = await showDialog<bool>(
        context: context,
        builder: (_) => _DeleteConfirmDialog(
          taskTitle: task.title,
          toRecycle: _store.recycleBinEnabled,
        ),
      );
      if (answer == null) return false;
      disableConfirm = answer;
    }

    await _store.remove(task);
    if (disableConfirm) {
      await _store.setConfirmBeforeDelete(false);
    }
    return true;
  }

  /// 所有入口的唯一分发表。
  ///
  /// **不在这里关抽屉** —— 那样从「我的」页点入口会把主路由 pop 掉。
  /// 关抽屉由侧边栏自己做。
  /// 下载旧版（V5）：走更新器同一条管道 —— 下载、校验 sha256、交给系统安装器。
  ///
  /// 不自己写下载逻辑，也不直接跳浏览器：
  ///   - 同一条管道意味着有进度、有镜像回退（ghfast / gh-proxy）、有摘要校验
  ///   - 走浏览器的话国内经常打不开，用户只会觉得"链接坏了"
  ///
  /// 包名不同，所以系统把 5.5.28 当**另一个 App** 装，不会覆盖 V6。
  /// 自动路径失败时才退回到"让用户自己挑通道"。
  Future<void> _downloadLegacy() async {
    // **先问机型再决定下哪个包**：arm64 是 23MB，通用整包 62MB，差将近 3 倍。
    // loadAbi 失败返回 null，那就回落整包 —— 宁可多花流量，不能装不上。
    final abi = await AppUpdateProvider.loadAbi();
    if (!mounted) return;
    final sizeMb = LegacyV5Link.sizeLabelFor(abi);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载任务管家 ${LegacyV5Link.version}？',
            style: const TextStyle(fontSize: 16)),
        content: Text(
          '$sizeMb。\n'
          '它和你正在用的这个版本是两个 App，不会覆盖；装完桌面上会多一个图标。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('下载并安装')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<double>(0);
    var dialogClosed = false;

    void closeDialog() {
      if (dialogClosed || !mounted) return;
      dialogClosed = true;
      Navigator.of(context).pop();
    }

    // 进度框：不 await，下载在下面跑；结束时由 closeDialog 收掉
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('正在下载旧版…', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 14),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, value, _) => LinearProgressIndicator(value: value <= 0 ? null : value),
            ),
            const SizedBox(height: 10),
            Text('下载完会拉起系统安装器', style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    ));

    try {
      final result = await AppUpdateLauncher().apply(
        LegacyV5Link.targetFor(abi),
        onProgress: (value) => progress.value = value,
      );
      closeDialog();
      if (!mounted) return;
      _toast(result == AppUpdateLaunchResult.installStarted
          ? '下载完成，按系统提示安装即可'
          : '已打开下载页，装好后桌面上会多一个图标');
    } catch (error) {
      closeDialog();
      if (!mounted) return;
      _toast('自动下载失败：$error');
      await _pickLegacyChannel(manualOnly: true, abi: abi);
    } finally {
      progress.dispose();
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
  }

  /// 自动路径失败后的手动通道（也让用户能绕过公共代理自己想办法）
  Future<void> _pickLegacyChannel({bool manualOnly = false, String? abi}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
              child: Text(manualOnly ? '换个方式下载 ${LegacyV5Link.version}' : '下载任务管家 ${LegacyV5Link.version}',
                  style: const TextStyle(fontSize: 15)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(LegacyV5Link.stableHint,
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant)),
            ),
            for (final channel in LegacyV5Link.channelsFor(abi))
              ListTile(
                dense: true,
                title: Text(channel.label, style: const TextStyle(fontSize: 14)),
                subtitle: channel.note == null
                    ? null
                    : Text(channel.note!, style: const TextStyle(fontSize: 11.5)),
                trailing: const Icon(Icons.open_in_new, size: 16),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  AppUpdateLauncher().openDownloadPage(Uri.parse(channel.url));
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openDestination(AppDestination destination) {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    if (!destination.ready) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('「${destination.label}」还没接入'),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    switch (destination) {
      case AppDestination.todayTasks:
        setState(() => _tab = 0);
      case AppDestination.tagManager:
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => TagManagerPage(store: _store)),
        );
      case AppDestination.fieldManager:
        final fields = widget.fieldStore;
        if (fields == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('字段管理未接入'), duration: Duration(seconds: 1)),
          );
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => FieldManagerPage(store: fields)),
        );
      case AppDestination.homeMode:
        final home = widget.homeStore;
        if (home == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('首页模式未接入'), duration: Duration(seconds: 1)),
          );
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => HomeModePage(
              store: home,
              plugins: widget.marketStore?.active ?? const <InstalledPlugin>[],
              nameOf: _pluginName,
            ),
          ),
        );
      case AppDestination.recycleBin:
        final builder = widget.recyclePageBuilder;
        if (builder == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('回收站未接入'), duration: Duration(seconds: 1)),
          );
          return;
        }
        navigator.push(MaterialPageRoute<void>(builder: builder));
      case AppDestination.about:
        final about = widget.aboutPageBuilder;
        if (about == null) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('关于页未接入（没有更新器）'),
              duration: Duration(seconds: 1),
            ),
          );
          return;
        }
        navigator.push(MaterialPageRoute<void>(builder: about));
      case AppDestination.settings:
        final store = _store;
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsPage(
              store: store,
              calendarStyle: _calendarStyle,
              onCalendarStyleChanged: (style) =>
                  setState(() => _calendarStyle = style),
              onRetentionDaysChanged: _setRetentionDays,
              onOpenDestination: _openDestination,
              pluginSummary: _pluginSummary,
              onDownloadLegacy: _downloadLegacy,
              onOpenBackup: widget.backupPageBuilder == null
                  ? null
                  : () => navigator.push(
                        MaterialPageRoute<void>(builder: widget.backupPageBuilder!),
                      ),
            ),
          ),
        );
      case AppDestination.pluginMarket:
        final market = widget.marketStore;
        if (market == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('插件市场未接入'), duration: Duration(seconds: 1)),
          );
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => PluginMarketPage(store: market)),
        );
    }
  }

  /// 把逾期任务全部挪到当前选中的那天。
  ///
  /// 用"移到这天"而不是"移到今天"：用户可能正在看明天的安排，
  /// 看到逾期后想顺手排到明天 —— 按钮跟着当前选中日走才符合直觉。
  Future<void> _moveOverdueToSelectedDay() async {
    final moved = await _store.moveAllOverdueTo(_selected);
    if (!mounted || moved == 0) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已把 $moved 条逾期任务移到${_selected.month}月${_selected.day}日'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 沿用 v5 的习惯：双击顶栏日期回到今天（不放实体按钮，避免破坏观感）
  void _jumpToToday() {    final today = DateTime.now();
    setState(() {
      _selected = today;
      _resetSignal++;
    });
    _store.load(today);
  }

  void _selectDate(DateTime d) {
    setState(() => _selected = d);
    _store.load(d);
  }

  /// 新建任务：和编辑用同一个页面（字段一次填完）。
  ///
  /// 以前是一个只有标题的弹窗，用户建完想加日期/优先级/标签还得再进去改一次 ——
  /// 那等于所有任务都要操作两遍。现在默认从底部升起，不离场也能填全。
  Future<void> _addTask() async {
    final outcome = await showTaskEditor(
      context,
      store: _store,
      fields: widget.fieldStore,
      initialDay: _selected,
    );
    if (!mounted || outcome == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('已添加'), duration: Duration(seconds: 2)),
      );
  }

  /// 左滑到底时先问一句。返回 false 时 `Dismissible` 会把卡片弹回原位。
  Future<bool> _confirmDelete(Task task) async {
    _pendingDisableConfirm = false;

    if (_store.confirmBeforeDelete) {
      // null = 取消；false = 删除但继续提醒；true = 删除且不再提醒
      final dontAskAgain = await showDialog<bool>(
        context: context,
        builder: (_) => _DeleteConfirmDialog(
        taskTitle: task.title,
        toRecycle: _store.recycleBinEnabled,
      ),
      );
      if (dontAskAgain == null) return false;
      _pendingDisableConfirm = dontAskAgain;
    }

    // **单一出口**：只要放行就登记待删除，不管刚才有没有弹窗。
    // 这行以前只在弹窗分支里执行 —— 关掉确认后 `onDismissed` 就认领不到，
    // 任务只从界面消失、库里还在，切个日期它就复活了。
    _deletes.schedule(task);
    return true;
  }

  void _handleDismissed(Task task) {
    _deletes.cancel(task.id); // 只收尾；删不删由 _applyDelete 自己幂等判断
    _applyDelete(task);
  }

  Future<void> _applyDelete(Task task) async {
    // 幂等：兜底定时器与 onDismissed 可能都走到这里，第二次直接退出
    if (!_store.tasks.any((t) => t.id == task.id)) return;

    final disabledConfirm = _pendingDisableConfirm;
    _pendingDisableConfirm = false;

    await _store.remove(task);
    if (disabledConfirm) {
      await _store.setConfirmBeforeDelete(false);
    }
    if (!mounted) return;

    // 只给一条短提示。"怎么开回来"已经在弹窗里讲过了 ——
    // 放到这里做成长驻横幅既不在视觉中心，又依赖 SnackBar 的自动关闭计时，
    // 一旦计时没起来就会一直挂着。
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          [
            if (_store.recycleBinEnabled) '「${task.title}」已移入回收站' else '「${task.title}」已删除',
            if (disabledConfirm) '删除确认已关闭',
          ].join(' · '),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu),
                tooltip: '侧边栏',
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            title: _headerTitle(),
            // 右侧是货币徽章插槽：没有生效货币时**什么都不显示**（见 docs/main-package.md §4.5）
            actions: <Widget>[?_badge],
          ),
          drawer: Drawer(
            width: MediaQuery.sizeOf(context).width * 0.58,
            child: SideNav(
              currentTab: _tab,
              onOpenDestination: _openDestination,
              installedPlugins: widget.marketStore?.active ?? const <InstalledPlugin>[],
              pluginNameOf: (id) => widget.marketStore?.index.findById(id)?.name ?? id,
              onOpenPlugin: _openPlugin,
            ),
          ),
          body: _buildBody(),
          bottomNavigationBar: _BottomBar(
            index: _tab,
            onSelect: (i) => setState(() => _tab = i),
            // 插件模式下不给 `+`：主包不知道插件里「新建」是什么（写日记？记一笔？），
            // 留一个 `+` 去建任务，用户会以为"新加的东西没存上"。
            onAdd: _modeAllowsAdd ? _addTask : null,
          ),
        );
      },
    );
  }

  /// 首页内容区：插件整页优先，否则用内置的任务视图。
  ///
  /// **插件换的只是这一块**：顶栏、底栏、`+` 按钮、侧边栏都不动。
  Widget _homeView() {
    return _pluginHome() ?? _builtinHome();
  }

  // ---- 模式切换（顶栏） ----

  /// 顶栏标题：内置模式显示日期，插件模式显示插件名。
  ///
  /// 后面挂一个小箭头 —— 模式要**随手可切**。进设置改单选离得太远，
  /// 用户会宁可不用多模式。
  ///
  /// 双击回今天只保留在内置模式：插件模式下日历条根本不可见，
  /// 回"今天"没有任何可看的东西，留着只会让人以为切坏了。
  Widget _headerTitle() {
    final home = widget.homeStore;
    final isBuiltin = home == null || home.mode.isBuiltin;
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

    if (isBuiltin) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _jumpToToday,
            child: Text(_dateLabel, key: const Key('v6-header-date'), style: style),
          ),
          // 没有 homeStore（测试里）就不给切换入口：点了也没地方落状态
          if (home != null) _modeCaret(),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          _pluginName(home.mode.pluginId!),
          key: const Key('v6-header-mode'),
          style: style,
        ),
        _modeCaret(),
      ],
    );
  }

  Widget _modeCaret() {
    return InkResponse(
      onTap: _openModeSwitcher,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
        child: Icon(
          Icons.unfold_more,
          size: 17,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _openModeSwitcher() {
    final home = widget.homeStore;
    if (home == null) return;
    showModeSwitcher(
      context,
      store: home,
      plugins: widget.marketStore?.active ?? const <InstalledPlugin>[],
      nameOf: _pluginName,
      onOpenManager: () => _openDestination(AppDestination.homeMode),
    );
  }

  /// 「我的」页顶部那行货币文案。
  ///
  /// 没装货币插件时保持"未安装"，装了之后显示名字与余额 ——
  /// 用户得能看出顶栏那个数字是谁给的。
  String get _currencyLabel {
    final currency = widget.currencyStore;
    if (currency == null || !currency.installed) return '当前货币：未安装';
    final id = currency.providerId!;
    return '当前货币：${_pluginName(id)} · ${currency.balance}';
  }

  /// 「我的」页第二行：装了几个、启用几个。
  ///
  /// 停用中的插件也算"装了"—— 用户对"我装过什么"和"现在生效的有几个"
  /// 是两件事，分开写才不至于让他以为插件丢了。
  String get _pluginSummary {
    final market = widget.marketStore;
    if (market == null) return '插件未接入';
    final installed = market.installed.length;
    if (installed == 0) return '还没装插件 · 去插件市场看看';
    return '已装 $installed 个插件 · 启用 ${market.active.length} 个';
  }

  /// 当前模式是否允许用 `+` 建任务。插件模式下不允许（见 [build] 里的注释）。
  bool get _modeAllowsAdd {
    final home = widget.homeStore;
    return home == null || home.mode.isBuiltin;
  }

  Widget _builtinHome() {
    return V6HomePage(
      selected: _selected,
      tasks: _store.visible,
      overdue: _store.overdue,
      onMoveOverdueToSelectedDay: _moveOverdueToSelectedDay,
      tags: _store.tags,
      tagFilter: _store.tagFilter,
      onSelectTag: _store.setTagFilter,
      calendarStyle: _calendarStyle,
      resetSignal: _resetSignal,
      marks: _calendarMarks,
      extraLineFor: _extraLineFor,
      onSelectDate: _selectDate,
      onToggle: _store.toggle,
      onBeforeDelete: _confirmDelete,
      onDeleted: _handleDismissed,
      onEdit: _openEditor,
    );
  }

  Widget? get _badge {
    // 提供货币的插件已经卸掉了，就别再挂着一个没人维护的数字。
    // 这里只做"不显示"，不动持久化 —— 用户重装同一个插件后余额自然回来。
    final currency = widget.currencyStore;
    final market = widget.marketStore;
    if (currency != null && currency.installed && market != null) {
      final alive = market.active.any((p) => p.pluginId == currency.providerId);
      if (!alive) return null;
    }
    final slot = SlotRegistry.instance.resolve(SlotId.currencyBadge);
    if (slot is! CurrencyBadgeValue) return null;
    return _CurrencyBadge(value: slot.value);
  }

  Widget _buildBody() {
    // 只在**首次**还没拿到数据时显示全屏加载。
    // 用 `loading` 判断会让切日期也换掉整棵树，日历条随之销毁重建、滚动位置跳回。
    if (!_store.ready) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return IndexedStack(
      index: _tab,
      children: <Widget>[
        // 首页可以被插件整页替换，但**外壳还是这一层**：
        // 顶栏、底栏、添加按钮都在外面，插件崩了用户总能切回「我的」。
        _homeView(),
        // 开关全搬去设置页了，这里只剩身份与入口
        ProfileStubPage(
          currencyLabel: _currencyLabel,
          pluginSummary: _pluginSummary,
          onOpenDestination: _openDestination,
        ),
      ],
    );
  }
}

class _CurrencyBadge extends StatelessWidget {
  const _CurrencyBadge({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFFFB300).withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.bolt, size: 13, color: Color(0xFFF57F17)),
              const SizedBox(width: 2),
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF57F17),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onSelect, this.onAdd});

  final int index;
  final ValueChanged<int> onSelect;

  /// 为 null 时**不画**中间那个添加按钮（插件模式）。
  /// 隐藏而不是禁用：灰掉的按钮看着像"哪里没配置对"，还会一直被点。
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: 58,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(child: _item('首页', 0)),
                    const SizedBox(width: 64),
                    Expanded(child: _item('我的', 1)),
                  ],
                ),
              ),
            ),
            if (onAdd != null)
              Positioned(
                top: -12,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: scheme.primary,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onAdd,
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: Icon(Icons.add, color: scheme.onPrimary, size: 24),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _item(String label, int i) {
    return Builder(builder: (context) {
      final selected = index == i;
      final scheme = Theme.of(context).colorScheme;
      return InkWell(
        onTap: () => onSelect(i),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    });
  }
}

/// 删除确认框。
///
/// 返回值：`null` = 取消；`false` = 删除但继续提醒；`true` = 删除且不再提醒。
class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({required this.taskTitle, required this.toRecycle});

  final String taskTitle;

  /// 决定文案：开着回收站说"移入回收站"，关着就是"彻底删除"。
  /// 以前无论哪种都写"移入回收站"，默认关回收站时会骗人。
  final bool toRecycle;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  bool _dontAskAgain = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('删除任务', style: TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.toRecycle
                ? '「${widget.taskTitle}」将移入回收站。'
                : '「${widget.taskTitle}」将被彻底删除，无法恢复。',
            style: const TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _dontAskAgain = !_dontAskAgain),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: _dontAskAgain,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => setState(() => _dontAskAgain = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '以后不再提醒',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          // 勾上的那一刻就把后果讲清楚：这里在视觉中心，比事后的底部横幅可靠得多
          if (_dontAskAgain) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, size: 13, color: scheme.primary),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '关闭后可在「我的 › 删除前确认」重新开启',
                    style: TextStyle(fontSize: 11.5, height: 1.35, color: scheme.primary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_dontAskAgain),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: const Text('删除'),
        ),
      ],
    );
  }
}
