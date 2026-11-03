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
  });

  final TaskStore store;
  final PluginMarketStore? marketStore;
  final Future<PluginLaunchSpec> Function(InstalledPlugin plugin)? pluginLauncher;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  /// 计划插件给的"未来几天安排"。null = 还没拿到或没有。
  List<_PlanDay>? _planDays;
  bool _planLoading = false;
  String? _planNote;

  /// 备忘插件给的置顶条目。
  List<_MemoItem>? _memoItems;
  bool _memoLoading = false;

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

  void _onMarketChanged() {
    if (_planDays == null && !_planLoading) {
      unawaited(_loadPlanBlock());
    }
    if (_memoItems == null && !_memoLoading) {
      unawaited(_loadMemoBlock());
    }
  }

  @override
  void dispose() {
    widget.marketStore?.removeListener(_onMarketChanged);
    // 策略 3：离屏 WebView 跟随本页生命周期，离开就释放。
    unawaited(PluginQueryHost.instance.releaseAll());
    super.dispose();
  }

  /// 拉"今日计划"块。
  ///
  /// 三步都可能失败（没装插件 / 没声明 queryEntry / 超时），**每一步失败都只是
  /// 这一块不出现**，绝不影响上面的任务列表。
  Future<void> _loadPlanBlock() async {
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
      debugPrint('[today] 跳过计划块：没有可用的周计划插件');
      return;
    }

    setState(() => _planLoading = true);
    debugPrint('[today] 加载计划块：${plugin.pluginId} v${plugin.version}');
    try {
      debugPrint('[today] ① 调用 launcher');
      final spec = await launcher(plugin);
      debugPrint('[today] ② launcher 返回，开始 acquire');
      // **必须用 directoryOf**：`plugin.installDir` 是相对值（`id/version`），
      // 拿它去 File() 会找不到清单，表现为"插件装了但查不到"。
      final directory = await market.installer.directoryOf(plugin);
      final ok = await PluginQueryHost.instance.acquire(
        plugin.pluginId,
        directory,
        dispatch: spec.bridge.dispatch,
      );
      debugPrint('[today] ③ acquire 返回 $ok');
      if (!ok) {
        if (mounted) setState(() => _planLoading = false);
        return;
      }

      final to = _from.add(const Duration(days: 7));
      debugPrint('[today] ④ 开始查询 plan.list');
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
        // 不弹错：这块拿不到就是没有，界面保持安静
        setState(() {
          _planLoading = false;
          _planNote = result.status == QueryStatus.unsupported
              ? '计划插件未提供该查询'
              : null;
        });
        return;
      }

      final days = _parseDays(result.data);
      setState(() {
        _planDays = days;
        _planLoading = false;
      });
    } catch (error) {
      debugPrint('[today] 计划块加载失败：$error');
      if (mounted) setState(() => _planLoading = false);
    }
  }

  /// 拉"置顶备忘"块。和计划块同一套机制，只是方法名不同。
  Future<void> _loadMemoBlock() async {
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
    if (plugin == null) return;

    setState(() => _memoLoading = true);
    try {
      final spec = await launcher(plugin);
      final directory = await market.installer.directoryOf(plugin);
      final ok = await PluginQueryHost.instance.acquire(
        plugin.pluginId,
        directory,
        dispatch: spec.bridge.dispatch,
      );
      if (!ok) {
        if (mounted) setState(() => _memoLoading = false);
        return;
      }
      final result = await PluginQueryRegistry.instance.query(
        plugin.pluginId,
        'memo.pinned',
      );
      if (!mounted) return;
      if (!result.isOk) {
        setState(() => _memoLoading = false);
        return;
      }
      setState(() {
        _memoItems = _parseMemos(result.data);
        _memoLoading = false;
      });
    } catch (error) {
      debugPrint('[today] 备忘块加载失败：$error');
      if (mounted) setState(() => _memoLoading = false);
    }
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

  static List<_PlanDay> _parseDays(Map<String, Object?>? data) {
    final raw = data?['days'];
    if (raw is! List) return const <_PlanDay>[];
    final days = <_PlanDay>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final date = item['date'];
      final count = item['count'];
      if (date is! String) continue;
      days.add(_PlanDay(
        int.tryParse(date.split('-').last) ?? 0,
        count is int ? count : 0,
      ));
    }
    return days;
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
          _block('置顶备忘', _memoContent(scheme)),
        ],
        if (_planLoading || _planDays != null || _planNote != null) ...<Widget>[
          const SizedBox(height: 14),
          _block('未来七天', _planContent(scheme)),
        ],
      ],
    );
  }

  Widget _block(String title, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final task in tasks)
          Padding(
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
              ],
            ),
          ),
      ],
    );
  }

  Widget _memoContent(ColorScheme scheme) {
    if (_memoLoading) {
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
    if (_planLoading) {
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
    final days = _planDays ?? const <_PlanDay>[];
    if (days.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('这周还没有安排',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final d in days)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${d.day} 日 · ${d.count} 件',
              style: TextStyle(fontSize: 12, color: scheme.onSurface),
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

class _PlanDay {
  const _PlanDay(this.day, this.count);
  final int day;
  final int count;
}
