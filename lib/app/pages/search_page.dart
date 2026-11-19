import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/plugin/plugin_query_host.dart';
import '../../core/plugin/plugin_query_registry.dart';
import '../../core/plugin/plugin_store.dart';
import '../models/task.dart';
import '../state/plugin_market_store.dart';
import '../state/task_store.dart';
import 'plugin_page.dart';

/// 全局搜索（6.8）。
///
/// 第一步只搜任务 —— 装不装插件都能用。插件那几组（计划 / 备忘 / 清单 / 日记）
/// 接着往 `_sections` 里加，页面结构不用动。
///
/// 结果**按类型分组**而不是混排：跨插件的"相关度"没有共同标尺，
/// 硬排只会让用户觉得"凭什么它在第一"（2026-11-19 定）。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    this.onOpenTask,
    this.marketStore,
    this.pluginLauncher,
    this.onOpenPlugin,
  });

  final TaskStore store;
  final ValueChanged<Task>? onOpenTask;

  /// 插件搜索要的三样：装了哪些、怎么拿到查询通道、点了往哪跳。
  final PluginMarketStore? marketStore;
  final Future<PluginLaunchSpec> Function(InstalledPlugin plugin)? pluginLauncher;
  final void Function(String pluginId, [Map<String, Object?>? openWith])?
      onOpenPlugin;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();

  /// 输入防抖：每敲一个字都查一次，弹键盘的同时发 SQL，手感会一顿一顿的。
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  Timer? _debounce;

  /// 请求序号。搜索对时效敏感：先发的请求后回来，会把新结果盖掉。
  int _seq = 0;

  String _keyword = '';
  bool _loading = false;
  List<Task> _tasks = const <Task>[];

  /// 插件结果：pluginId -> 命中项。
  final Map<String, List<_HitItem>> _pluginHits = <String, List<_HitItem>>{};

  /// 查不动的插件（没就绪 / 超时 / 报错）。底部用小字提示，不弹窗。
  final Set<String> _pluginMissed = <String>{};

  /// 参与搜索的插件。**写死清单**而不是遍历所有插件：
  /// 每个插件要各自实现 `*.search` 并按自己的表结构搜，不是所有插件都有可搜的内容
  /// （比如能量货币就没有）。这里是白名单，新增插件要显式加一行。
  static const List<_SearchTarget> _targets = <_SearchTarget>[
    _SearchTarget('plan_mode', '计划', 'plan.search', 'plan'),
    _SearchTarget('memo', '备忘', 'memo.search', 'memo'),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _run(value));
  }

  Future<void> _run(String raw) async {
    final keyword = raw.trim();
    final seq = ++_seq;

    if (keyword.isEmpty) {
      setState(() {
        _keyword = '';
        _tasks = const <Task>[];
        _loading = false;
      });
      return;
    }

    setState(() {
      _keyword = keyword;
      _loading = true;
      _pluginHits.clear();
      _pluginMissed.clear();
    });

    // 插件和任务并发：插件要起离屏 WebView，串行会让结果一行一行往外蹦。
    // 先让任务结果出现（本地 SQL 快），插件结果到了再追加，别让用户干等。
    final plugins = _searchPlugins(keyword, seq);
    final hits = await widget.store.search(keyword);
    // 期间又敲了字：这次结果已经过期，直接丢掉，别闪一下旧数据
    if (!mounted || seq != _seq) return;
    setState(() => _tasks = hits);

    await plugins;
    if (!mounted || seq != _seq) return;
    setState(() => _loading = false);
  }

  /// 并发查所有已启用的目标插件。没装的不参与，不报错。
  Future<void> _searchPlugins(String keyword, int seq) async {
    final market = widget.marketStore;
    final launcher = widget.pluginLauncher;
    if (market == null || launcher == null) return;

    final jobs = <Future<void>>[];
    for (final target in _targets) {
      InstalledPlugin? plugin;
      for (final p in market.installed) {
        if (p.pluginId == target.pluginId && p.enabled) {
          plugin = p;
          break;
        }
      }
      if (plugin == null) continue;
      jobs.add(_searchOne(target, plugin, keyword, seq, market, launcher));
    }
    await Future.wait(jobs);
  }

  Future<void> _searchOne(
    _SearchTarget target,
    InstalledPlugin plugin,
    String keyword,
    int seq,
    PluginMarketStore market,
    Future<PluginLaunchSpec> Function(InstalledPlugin) launcher,
  ) async {
    try {
      final spec = await launcher(plugin);
      // 必须用 directoryOf：installDir 是相对值，拿去当路径会读不到清单
      final directory = await market.installer.directoryOf(plugin);
      final ready = await PluginQueryHost.instance.acquire(
        plugin.pluginId,
        directory,
        dispatch: spec.bridge.dispatch,
      );
      if (!ready) {
        _markMissed(target.pluginId, seq);
        return;
      }
      final result = await PluginQueryRegistry.instance.query(
        plugin.pluginId,
        target.method,
        <String, Object?>{'keyword': keyword, 'limit': 20},
      );
      if (!result.isOk) {
        _markMissed(target.pluginId, seq);
        return;
      }

      final items = _parseHits(result.data);
      if (!mounted || seq != _seq) return;
      setState(() {
        _pluginHits[target.pluginId] = items;
        _pluginMissed.remove(target.pluginId);
      });
    } catch (error) {
      // 一个插件查不动不该让整页失败
      debugPrint('[search] ${target.pluginId} 查询失败：$error');
      _markMissed(target.pluginId, seq);
    }
  }

  void _markMissed(String pluginId, int seq) {
    if (!mounted || seq != _seq) return;
    setState(() => _pluginMissed.add(pluginId));
  }

  List<_HitItem> _parseHits(Object? data) {
    if (data is! Map) return const <_HitItem>[];
    final raw = data['items'];
    if (raw is! List) return const <_HitItem>[];
    final items = <_HitItem>[];
    for (final one in raw) {
      if (one is! Map) continue;
      final id = one['id'];
      final title = one['title'];
      // id 和 title 缺一个就没法跳/没法显示，直接丢
      if (id is! int || title is! String) continue;
      final subtitle = one['subtitle'];
      items.add(_HitItem(id, title, subtitle is String ? subtitle : ''));
    }
    return items;
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    _seq++;
    setState(() {
      _keyword = '';
      _tasks = const <Task>[];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _run,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: '搜任务、计划、备忘、清单、日记',
            hintStyle: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            border: InputBorder.none,
          ),
        ),
        actions: <Widget>[
          if (_keyword.isNotEmpty)
            IconButton(
              tooltip: '清空',
              onPressed: _clear,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: ListView(
        // 底部留出外壳底栏的高度，否则最后一条被压住点不到
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: _body(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_keyword.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            '输入关键词开始搜索。\n任务搜标题和描述，插件里的内容由各自的模式负责。',
            style: TextStyle(fontSize: 12.5, height: 1.8, color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }

    if (_loading && _tasks.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }

    final pluginTotal =
        _pluginHits.values.fold<int>(0, (sum, list) => sum + list.length);

    if (_tasks.isEmpty && pluginTotal == 0) {
      // 还在等插件：只说"没找到"会误导 —— 任务没有不代表插件没有
      if (_loading) {
        return <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ];
      }
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            _pluginMissed.isEmpty
                ? '没有找到「$_keyword」。'
                : '没有找到「$_keyword」。有模式没连上，可能漏了结果。',
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }

    // 已完成排在后面：SQL 里已经按 is_ok 升序，这里不再重排，
    // 避免"界面顺序"和"数据顺序"两套逻辑打架
    final doneCount = _tasks.where((t) => t.isDone).length;
    final openCount = _tasks.length - doneCount;

    return <Widget>[
      if (_tasks.isNotEmpty) ...<Widget>[
        Row(
        children: <Widget>[
          Text(
            '任务 ${_tasks.length}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          if (doneCount > 0)
            Text(
              '（未完成 $openCount · 已完成 $doneCount）',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          const Spacer(),
          if (_loading)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: scheme.primary),
            ),
        ],
      ),
      const SizedBox(height: 4),
      for (final task in _tasks) _taskRow(task, scheme),
      ],
      for (final target in _targets) ..._pluginSection(target, scheme),
      if (_pluginMissed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            '有模式没连上（超时或未就绪）：${_pluginMissed.join('、')}',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
    ];
  }

  /// 一个插件的结果分组。空组不渲染 —— 搜"牛奶"却看到「计划 0」，纯噪音。
  List<Widget> _pluginSection(_SearchTarget target, ColorScheme scheme) {
    final items = _pluginHits[target.pluginId];
    if (items == null || items.isEmpty) return const <Widget>[];
    final onOpen = widget.onOpenPlugin;

    return <Widget>[
      const SizedBox(height: 18),
      Text(
        '${target.label} ${items.length}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      for (final item in items)
        InkWell(
          // 带参数打开：插件自己决定怎么落到那一条（计划进详情、备忘记滚动并高亮）
          onTap: onOpen == null
              ? null
              : () => onOpen(target.pluginId, <String, Object?>{
                    'kind': target.kind,
                    'id': item.id,
                  }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: <Widget>[
                Icon(Icons.north_east, size: 14, color: scheme.outline),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                      if (item.subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            item.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
                if (onOpen != null)
                  Icon(Icons.chevron_right, size: 15, color: scheme.outline),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _taskRow(Task task, ColorScheme scheme) {
    final onOpen = widget.onOpenTask;
    final done = task.isDone;
    return InkWell(
      onTap: onOpen == null ? null : () => onOpen(task),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(
              done ? Icons.check_circle : Icons.circle_outlined,
              size: 16,
              color: done ? scheme.outline : scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      // 已完成的标灰 + 划线：一眼分得清"还要做的"和"做完的"
                      color: done ? scheme.onSurfaceVariant : scheme.onSurface,
                      decoration: done ? TextDecoration.lineThrough : null,
                      decorationColor: scheme.onSurfaceVariant,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      TaskDate.dayKey(task.dueDate),
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            if (onOpen != null)
              Icon(Icons.chevron_right, size: 15, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 一个参与搜索的插件。
@immutable
class _SearchTarget {
  const _SearchTarget(this.pluginId, this.label, this.method, this.kind);

  final String pluginId;

  /// 分组标题里显示的名字
  final String label;

  /// 查询方法名，走插件自己的 `host.onQuery`
  final String method;

  /// 跳转时带给插件的 `kind`
  final String kind;
}

/// 插件返回的一条命中。
@immutable
class _HitItem {
  const _HitItem(this.id, this.title, this.subtitle);

  final int id;
  final String title;
  final String subtitle;
}
