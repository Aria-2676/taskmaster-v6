import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';

/// 恢复完成后的报告。
///
/// 为什么不弹一个对话框：一次恢复可能同时出现"写了哪些段""哪些插件没恢复"
/// "哪些字段被丢弃"，三条以上对话框就挤成一团，用户也读不完。做成页面还能
/// 让用户慢慢看，看完再点完成。
class RestoreReportPage extends StatelessWidget {
  const RestoreReportPage({super.key, required this.report});

  final RestoreReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final written = report.written.entries.where((e) => e.value > 0).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('恢复报告', style: TextStyle(fontSize: 16)),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          _Section(
            title: report.hasLoss ? '恢复完成，但有东西没进来' : '恢复完成',
            tone: report.hasLoss ? _Tone.warn : _Tone.ok,
            children: <Widget>[
              if (written.isEmpty)
                const Text('没有写入任何数据', style: TextStyle(fontSize: 13))
              else
                for (final entry in written)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(entry.key, style: const TextStyle(fontSize: 13)),
                        ),
                        Text('${entry.value}',
                            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
            ],
          ),
          if (report.skippedPlugins.isNotEmpty)
            _Section(
              title: '这些没恢复（${report.skippedPlugins.length}）',
              tone: _Tone.warn,
              children: <Widget>[
                const Text(
                  '多半是当前没装那个插件、库里也没有它的表。想恢复就先把它装上，再恢复一次。',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 8),
                for (final id in report.skippedPlugins)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $id', style: const TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
          if (report.droppedColumns.isNotEmpty)
            _Section(
              title: '这些字段被忽略（${report.droppedColumns.length}）',
              tone: _Tone.warn,
              children: <Widget>[
                const Text(
                  '备份是旧版本打的，当前表里已经没有这些列。数据本身的其它字段都进去了。',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 8),
                for (final column in report.droppedColumns.take(20))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $column',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                if (report.droppedColumns.length > 20)
                  Text('等 ${report.droppedColumns.length} 个',
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
              ],
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

enum _Tone { ok, warn }

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.tone, required this.children});

  final String title;
  final _Tone tone;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone == _Tone.warn ? scheme.error : scheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    tone == _Tone.warn ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                    size: 18,
                    color: accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        style: TextStyle(fontSize: 14, color: accent)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
