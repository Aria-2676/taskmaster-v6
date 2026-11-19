import 'dart:async';

import 'package:flutter/material.dart';

import '../models/task.dart';
import '../state/task_store.dart';

/// 全局搜索（6.8）。
///
/// 第一步只搜任务 —— 装不装插件都能用。插件那几组（计划 / 备忘 / 清单 / 日记）
/// 接着往 `_sections` 里加，页面结构不用动。
///
/// 结果**按类型分组**而不是混排：跨插件的"相关度"没有共同标尺，
/// 硬排只会让用户觉得"凭什么它在第一"（2026-11-19 定）。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.store, this.onOpenTask});

  final TaskStore store;
  final ValueChanged<Task>? onOpenTask;

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
    });

    final hits = await widget.store.search(keyword);
    // 期间又敲了字：这次结果已经过期，直接丢掉，别闪一下旧数据
    if (!mounted || seq != _seq) return;
    setState(() {
      _tasks = hits;
      _loading = false;
    });
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

    if (_tasks.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            '没有找到「$_keyword」相关的任务。',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }

    // 已完成排在后面：SQL 里已经按 is_ok 升序，这里不再重排，
    // 避免"界面顺序"和"数据顺序"两套逻辑打架
    final doneCount = _tasks.where((t) => t.isDone).length;
    final openCount = _tasks.length - doneCount;

    return <Widget>[
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
