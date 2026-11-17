import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/plugin/plugin_query_host.dart';
import '../../core/plugin/plugin_query_registry.dart';
import '../../core/plugin/plugin_store.dart';
import 'plugin_page.dart';
import '../models/task.dart';
import '../state/plugin_market_store.dart';
import '../state/task_store.dart';

/// 今日页：主包内嵌的聚合页（`docs/decisions.md` 2026-11-03）。
///
/// **一个插件都不装也要有内容** —— 主包自己的部分（逾期 + 当天任务）先渲染，
/// 插件块随后到、到了再填。所以这里的加载顺序是"主包同步、插件异步"。
class TodayPage extends StatefulWidget {
  const TodayPage({
    super.key,
    required this.store,
    this.marketStore,
    this.pluginLauncher,
    this.active = true,
    this.onOpenPlugin,
    this.onOpenTask,
  });

  final TaskStore store;
  final PluginMarketStore? marketStore;
  final Future<PluginLaunchSpec> Function(InstalledPlugin plugin)? pluginLauncher;

  /// 打开已装插件（按 id）。今日页的块是**入口**，不是终点 ——
  /// 看到「置顶备忘」想改，看到计划进度想看阶段，都不该逼用户自己去找侧边栏。
  ///
  /// 第二个参数是"打开后落在哪儿"（见 [PluginLaunchSpec.openWith]）：
  /// 点某条计划就带上它的 id，插件直接进详情，不用再让用户在列表里找一遍。
  final void Function(String pluginId, [Map<String, Object?>? openWith])?
      onOpenPlugin;

  /// 打开任务编辑页。今日页只读，但"看到了想改"是常事。
  final void Function(Task task)? onOpenTask;

  /// 今日页当前是不是正在显示的那个 tab。
  ///
  /// 今日页在 `IndexedStack` 里常驻，插件块拿到一次就停在那个快照上。
  /// 靠它判断"值不值得重拉"：不可见时重拉是白起一次离屏 WebView，
  /// 真正的刷新时机是下面两种 ——
  /// 1. 从别的 tab 切回今日（`active` false → true）
  /// 2. 从插件页 / 编辑页返回（route 重新成为最上层）
  final bool active;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  /// 计划插件给的"进行中的计划"。null = 还没拿到或没有。
  List<_PlanItem>? _planItems;
  bool _planLoading = false;
  String? _planNote;

  /// 备忘插件给的置顶条目。
  List<_MemoItem>? _memoItems;
  bool _memoLoading = false;

  /// 上一次加载时用的插件签名（`id@版本`）。
  ///
  /// 用它判断"要不要重拉"：签名没变不必重复起离屏 WebView，
  /// 但插件升级、重装、换版本时必须重拉，否则块里永远是旧版本算出来的数。
  String? _planSignature;
  String? _memoSignature;

  /// 信号合并用。快速切 tab、连按返回时不要连着开两个离屏 WebView。
  Timer? _reloadTimer;
  static const Duration _reloadDelay = Duration(milliseconds: 250);

  /// 上一轮还在跑时又来了刷新请求：记下来，跑完补一次，不能直接丢。
  bool _planDirty = false;
  bool _memoDirty = false;

  /// 查询回 `unsupported`、需要重建离屏页面再试。见 [_rebuildPlanQuery]。
  bool _needPlanRebuild = false;
  bool _needMemoRebuild = false;

  /// 上次见到「自己是不是最上层 route」。false → true 就是"从别的页面回来了"。
  bool _routeWasCurrent = true;

  /// 本月日历的起点（今天往后 7 天）。
  DateTime get _from {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    // 今日页和首页同时在 IndexedStack 里构建，这时插件列表可能还没读完
    // （`marketStore.installed` 是异步填的）。只靠 initState 一次会永远拿不到，
    // 所以监听它：列表到位后再补一次。
    widget.marketStore?.addListener(_onMarketChanged);
    unawaited(_loadPlanBlock());
    unawaited(_loadMemoBlock());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `ModalRoute.of` 会订阅 route 状态：从插件页 / 编辑页返回时这里会再走一遍。
    // 这比"在每个 push 点手动敲一遍"可靠 —— 漏一个点就是一处数据不联动，
    // 而且不会报错，只能等用户发现"我明明改了它怎么没变"。
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current && !_routeWasCurrent && widget.active) _scheduleReload();
    _routeWasCurrent = current;
  }

  @override
  void didUpdateWidget(covariant TodayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切回今日 tab：在首页/任务列表里勾掉的任务可能已经改变了计划进度
    if (widget.active && !oldWidget.active) _scheduleReload();
  }

  /// 把短时间内的多次"该刷了"合并成一次，然后强制重拉两个块。
  ///
  /// 250ms 是给"切 tab 的同时又点了返回"这种连击留的合并窗口，不是为了等数据。
  void _scheduleReload() {
    if (!mounted) return;
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDelay, () {
      if (!mounted || !widget.active) return;
      debugPrint('[today] 重拉插件块（切回今日 / 从别的页面返回）');
      unawaited(_loadPlanBlock(force: true));
      unawaited(_loadMemoBlock(force: true));
    });
  }

  /// 插件列表变了：签名一样的话 [loadXxx] 会自己跳过，这里不必再判断。
  void _onMarketChanged() {
    unawaited(_loadPlanBlock());
    unawaited(_loadMemoBlock());
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    widget.marketStore?.removeListener(_onMarketChanged);
    // 策略 3：离屏 WebView 跟随本页生命周期，离开就释放。
    unawaited(PluginQueryHost.instance.releaseAll());
    super.dispose();
  }

  /// 拉"今日计划"块。
  ///
  /// 三步都可能失败（没装插件 / 没声明 queryEntry / 超时），**每一步失败都只是
  /// 这一块不出现**，绝不影响上面的任务列表。
  ///
  /// [force] 为 true 时无条件重拉。不强制时按签名（`id@版本`）判断：签名一样就
  /// 直接返回，因为市场通知 / 切 tab / 从别的页面返回会连着响，每次都起一个离屏
  /// WebView 太贵，而那样拉回来的还是同一份数据。
  Future<void> _loadPlanBlock({bool force = false, bool retried = false}) async {
    final market = widget.marketStore;
    final launcher = widget.pluginLauncher;
    if (market == null || launcher == null) {
      debugPrint('[today] 跳过计划块：market=${market != null} launcher=${launcher != null}');
      return;
    }

    InstalledPlugin? plugin;
    for (final p in market.installed) {
      if (p.pluginId == 'plan_mode' && p.enabled) {
        plugin = p;
        break;
      }
    }
    if (plugin == null) {
      debugPrint('[today] 计划块：没有启用的 plan_mode 插件');
      // 插件被卸载/停用：块要收回去，别把上一次的内容留着冒充现状
      if (_planItems != null && mounted) {
        setState(() {
          _planItems = null;
          _planNote = null;
          _planSignature = null;
        });
      }
      return;
    }

    final signature = '${plugin.pluginId}@${plugin.version}';
    if (!force && signature == _planSignature) return;

    if (_planLoading) {
      // 上一轮还没跑完（切 tab 很快、或返回时市场又通知一次）。
      // 直接丢掉这次请求会让界面停在更旧的版本上，所以记下来跑完补一次。
      _planDirty = true;
      return;
    }

    setState(() => _planLoading = true);
    debugPrint('[today] 加载计划块：$signature（force=$force）');
    try {
      final spec = await launcher(plugin);
      // **必须用 directoryOf**：`plugin.installDir` 是相对值（`id/version`），
      // 拿它去 File() 会找不到清单，表现为"插件装了但查不到"。
      final directory = await market.installer.directoryOf(plugin);
      final ok = await PluginQueryHost.instance.acquire(
        plugin.pluginId,
        directory,
        dispatch: spec.bridge.dispatch,
      );
      debugPrint('[today] acquire 返回 $ok');
      if (!ok) return;

      final to = _from.add(const Duration(days: 7));
      final result = await PluginQueryRegistry.instance.query(
        plugin.pluginId,
        'plan.list',
        <String, Object?>{
          'from': _dateKey(_from),
          'to': _dateKey(to),
        },
      );
      if (!mounted) return;

      if (!result.isOk) {
        if (result.status == QueryStatus.unsupported && !retried) {
          // 页面在、handler 却没了：WebView 被系统回收后 JS 上下文重建，而
          // `ready` 还记着"就绪"，于是永远等不到 handler。重建一次再问 ——
          // 不这么做界面会一直写"未提供该查询"，但插件其实是支持的
          // （2026-11-16 今日页计划块就停在这句话上）。
          debugPrint('[today] 计划块 unsupported，重建离屏页面后重试');
          _needPlanRebuild = true;
          return;
        }
        // 不弹错：这块拿不到就是没有，界面保持安静
        setState(() {
          _planNote = result.status == QueryStatus.unsupported
              ? '计划插件未提供该查询'
              : null;
          _planSignature = signature;
        });
        return;
      }

      setState(() {
        _planItems = _parsePlans(result.data);
        _planNote = null;
        _planSignature = signature;
      });
    } catch (error) {
      debugPrint('[today] 计划块加载失败：$error');
    } finally {
      if (mounted) setState(() => _planLoading = false);
      if (_needPlanRebuild) {
        _needPlanRebuild = false;
        unawaited(_rebuildPlanQuery(plugin.pluginId));
      } else if (_planDirty) {
        _planDirty = false;
        unawaited(_loadPlanBlock(force: true));
      }
    }
  }

  /// 重建计划插件的离屏页面，再问一次（只重试一次，[retried] 拦住死循环）。
  Future<void> _rebuildPlanQuery(String pluginId) async {
    await PluginQueryHost.instance.release(pluginId);
    if (!mounted) return;
    await _loadPlanBlock(force: true, retried: true);
  }

  /// 拉"置顶备忘"块。和计划块同一套机制，只是方法名不同。
  Future<void> _loadMemoBlock({bool force = false, bool retried = false}) async {
    final market = widget.marketStore;
    final launcher = widget.pluginLauncher;
    if (market == null || launcher == null) return;

    InstalledPlugin? plugin;
    for (final p in market.installed) {
      if (p.pluginId == 'memo' && p.enabled) {
        plugin = p;
        break;
      }
    }
    if (plugin == null) {
      debugPrint('[today] 备忘块：没有启用的 memo 插件');
      if (_memoItems != null && mounted) {
        setState(() {
          _memoItems = null;
          _memoSignature = null;
        });
      }
      return;
    }

    final signature = '${plugin.pluginId}@${plugin.version}';
    if (!force && signature == _memoSignature) return;

    if (_memoLoading) {
      _memoDirty = true;
      return;
    }

    setState(() => _memoLoading = true);
    try {
      final spec = await launcher(plugin);
      final directory = await market.installer.directoryOf(plugin);
      final ok = await PluginQueryHost.instance.acquire(
        plugin.pluginId,
        directory,
        dispatch: spec.bridge.dispatch,
      );
      if (!ok) return;
      final result = await PluginQueryRegistry.instance.query(
        plugin.pluginId,
        'memo.pinned',
      );
      if (!mounted) return;
      if (!result.isOk) {
        if (result.status == QueryStatus.unsupported && !retried) {
          debugPrint('[today] 备忘块 unsupported，重建离屏页面后重试');
          _needMemoRebuild = true;
          return;
        }
        setState(() => _memoSignature = signature);
        return;
      }
      setState(() {
        _memoItems = _parseMemos(result.data);
        _memoSignature = signature;
      });
    } catch (error) {
      debugPrint('[today] 备忘块加载失败：$error');
    } finally {
      if (mounted) setState(() => _memoLoading = false);
      if (_needMemoRebuild) {
        _needMemoRebuild = false;
        unawaited(_rebuildMemoQuery(plugin.pluginId));
      } else if (_memoDirty) {
        _memoDirty = false;
        unawaited(_loadMemoBlock(force: true));
      }
    }
  }

  Future<void> _rebuildMemoQuery(String pluginId) async {
    await PluginQueryHost.instance.release(pluginId);
    if (!mounted) return;
    await _loadMemoBlock(force: true, retried: true);
  }

  static List<_MemoItem> _parseMemos(Map<String, Object?>? data) {
    final raw = data?['items'];
    if (raw is! List) return const <_MemoItem>[];
    final items = <_MemoItem>[];
    for (final one in raw) {
      if (one is! Map) continue;
      final content = one['content'];
      if (content is String) items.add(_MemoItem(content));
    }
    return items;
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static List<_PlanItem> _parsePlans(Map<String, Object?>? data) {
    final raw = data?['plans'];
    if (raw is! List) return const <_PlanItem>[];
    final items = <_PlanItem>[];
    for (final one in raw) {
      if (one is! Map) continue;
      final name = one['name'];
      if (name is! String) continue;
      final percent = one['percent'];
      final endDate = one['endDate'];
      final id = one['id'];
      items.add(_PlanItem(
        id is int ? id : 0,
        name,
        percent is int ? percent : 0,
        endDate is String ? endDate : '',
      ));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = widget.store;
    final day = store.day;
    final overdue = store.overdue;
    final visible = store.visible;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: <Widget>[
        Text(
          '${day.month} 月 ${day.day} 日',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          '逾期 ${overdue.length} · 这天 ${visible.length}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (overdue.isNotEmpty) ...<Widget>[
          _block('逾期', _taskList(overdue, scheme)),
          const SizedBox(height: 14),
        ],
        _block('这天的安排', _taskList(visible, scheme)),
        if (_memoLoading || (_memoItems?.isNotEmpty ?? false)) ...<Widget>[
          const SizedBox(height: 14),
          _block(
            '置顶备忘',
            _memoContent(scheme),
            onTap: widget.onOpenPlugin == null
                ? null
                : () => widget.onOpenPlugin!('memo'),
          ),
        ],
        if (_planLoading || _planItems != null || _planNote != null) ...<Widget>[
          const SizedBox(height: 14),
          _block(
            '计划',
            _planContent(scheme),
            onTap: widget.onOpenPlugin == null
                ? null
                : () => widget.onOpenPlugin!('plan_mode'),
          ),
        ],
      ],
    );
  }

  /// 一个带小标题的块。
  ///
  /// [onTap] 不为空时整块可点，标题后面加一个 `›` —— 只有箭头没有热区、
  /// 或者只有热区没有箭头，都是"看着像能点 / 其实点不到"的典型。
  Widget _block(String title, Widget child, {VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (onTap != null) ...<Widget>[
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 15, color: scheme.onSurfaceVariant),
            ],
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: body,
    );
  }

  Widget _taskList(List<Task> tasks, ColorScheme scheme) {
    if (tasks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('没有任务',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    final onOpen = widget.onOpenTask;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final task in tasks)
          InkWell(
            onTap: onOpen == null ? null : () => onOpen(task),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: <Widget>[
                  Icon(
                    task.isDone ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    color: task.isDone ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        decoration: task.isDone ? TextDecoration.lineThrough : null,
                        color: task.isDone ? scheme.onSurfaceVariant : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (onOpen != null)
                    Icon(Icons.chevron_right, size: 15, color: scheme.outline),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _memoContent(ColorScheme scheme) {
    // 刷新时不显示「读取中…」：那会把已有内容闪掉，看着像数据丢了。
    // 只有"手上还没有内容"时才提示正在加载。
    if (_memoLoading && _memoItems == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('读取中…',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    final items = _memoItems ?? const <_MemoItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.push_pin, size: 14, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _planContent(ColorScheme scheme) {
    // 同备忘块：已经拿到过内容就静默刷新，不闪「读取中…」
    if (_planLoading && _planItems == null && _planNote == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('读取中…',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    if (_planNote != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(_planNote!,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    final items = _planItems ?? const <_PlanItem>[];
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('还没有进行中的计划',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    final onOpen = widget.onOpenPlugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final item in items)
          InkWell(
            // 点哪条开哪条。整块只给"看全部"用（块标题那个箭头）。
            onTap: onOpen == null || item.id == 0
                ? null
                : () => onOpen('plan_mode', <String, Object?>{
                      'kind': 'plan',
                      'id': item.id,
                    }),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  Icon(Icons.flag_outlined, size: 14, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    item.endDate.isEmpty
                        ? '${item.percent}%'
                        : '${item.percent}% · 到 ${item.endDate}',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                  if (onOpen != null && item.id != 0)
                    Icon(Icons.chevron_right, size: 14, color: scheme.outline),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MemoItem {
  const _MemoItem(this.content);
  final String content;
}

class _PlanItem {
  const _PlanItem(this.id, this.name, this.percent, this.endDate);

  /// 计划行主键。点这一行时带给插件，让它直接进这条计划的详情。
  final int id;

  final String name;
  final int percent;
  final String endDate;
}
