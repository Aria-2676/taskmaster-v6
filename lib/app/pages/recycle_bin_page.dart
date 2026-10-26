import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/extension/extension_hook.dart';
import '../data/task_repository.dart';
import '../models/recycled_task.dart';
import '../models/task.dart' show TaskDate;

/// 回收站。只在「删除后先进回收站」开关打开时才会有内容。
///
/// 三种出口：
///   - **恢复**：拷回 `tasks`（拿新 id）。标签在删除时已被级联清掉，恢复后没有标签。
///   - **永久删除**：从 `recycled_tasks` 删掉这一行。
///   - **到期自动清理**：不在这里做，由启动时扫一遍（见 `TaskRepository.purgeRecycleOlderThan`）。
///
/// 为什么不做后台清理：这是离线应用，用户不开 app 的那些天里"过期数据还留着"
/// 没有任何实际影响，省掉一个常驻调度器。
class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({
    super.key,
    required this.repository,
    required this.retentionDays,
    this.onChanged,
  });

  final TaskRepository repository;
  final int retentionDays;

  /// 恢复/彻底删除之后通知外层（首页列表要跟着刷新）
  final VoidCallback? onChanged;

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<RecycledTask> _items = const <RecycledTask>[];
  Map<int, String> _tagNames = const <int, String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    // 进页面先按当前保留时长清一次。清理只在"有机会"的时候做
    // （启动 / 改保留时长 / 进这里），所以这一步不能省 ——
    // 否则页面上会一直挂着早就该清掉的条目，倒计时显示"即将清理"却不动。
    await widget.repository.purgeRecycleOlderThan(Duration(days: widget.retentionDays));

    final items = await widget.repository.recycledTasks();
    final tags = await widget.repository.allTags();
    if (!mounted) return;
    setState(() {
      _items = items;
      _tagNames = <int, String>{for (final t in tags) t.id: t.name};
      _loading = false;
    });
  }

  Future<void> _restore(RecycledTask item) async {
    await widget.repository.restoreFromRecycle(item.id);
    // 恢复后是**新 id**（老 id 让给自增序列了），payload 里给标题和时间就够 ——
    // 订阅方要的是"哪条任务回来了"，不是精确的行。
    unawaited(HookBus.instance.emit(
      HookId.taskRestored,
      payload: <String, Object?>{
        'title': item.title,
        'dueDate': TaskDate.dayKey(item.dueDate),
      },
    ));
    widget.onChanged?.call();
    await _reload();
    if (!mounted) return;
    _toast('已恢复「${item.title}」');
  }

  Future<void> _purgeOne(RecycledTask item) async {
    await widget.repository.purgeRecycled(item.id);
    await _reload();
    if (!mounted) return;
    _toast('已彻底删除「${item.title}」');
  }

  Future<void> _purgeAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站', style: TextStyle(fontSize: 16)),
        content: const Text('里面的任务会被彻底删除，无法恢复。', style: TextStyle(fontSize: 13.5)),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.repository.purgeAllRecycled();
    await _reload();
    if (!mounted) return;
    _toast('回收站已清空');
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站', style: TextStyle(fontSize: 16)),
        actions: <Widget>[
          if (_items.isNotEmpty)
            TextButton(onPressed: _purgeAll, child: const Text('清空')),
        ],
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.schedule, size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '保留 ${widget.retentionDays} 天，到期自动清理',
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _items.isEmpty ? _buildEmpty(scheme) : _buildList(scheme),
                ),
              ],
            ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.delete_outline, size: 34, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text('回收站是空的', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        final left = item.daysLeft(widget.retentionDays);

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: scheme.onSurface,
                        decoration: item.isDone ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_dayLabel(item.dueDate)} · ${left == 0 ? '即将清理' : '$left 天后清理'}',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                    if (_namesOf(item).isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: <Widget>[
                          for (final name in _namesOf(item))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                name,
                                style: TextStyle(fontSize: 10, color: scheme.primary),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _restore(item),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text('恢复', style: TextStyle(fontSize: 12.5)),
              ),
              IconButton(
                onPressed: () => _purgeOne(item),
                icon: Icon(Icons.delete_forever_outlined, size: 18, color: scheme.error),
                visualDensity: VisualDensity.compact,
                tooltip: '彻底删除',
              ),
            ],
          ),
        );
      },
    );
  }

  /// 标签快照里的 id → 名字。跳过已经被删掉的标签（那时恢复也会跳过）。
  List<String> _namesOf(RecycledTask item) => <String>[
        for (final id in item.tagIds)
          if (_tagNames[id] != null) _tagNames[id]!,
      ];

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final diff = DateTime(d.year, d.month, d.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    return '${d.month}月${d.day}日';
  }
}
