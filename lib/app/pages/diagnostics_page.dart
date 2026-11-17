import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_log.dart';

/// 插件诊断要展示的静态信息。全量模式为 null。
@immutable
class PluginDiagnostics {
  const PluginDiagnostics({
    required this.pluginId,
    required this.title,
    required this.version,
    required this.contract,
    required this.permissions,
    required this.entryPath,
  });

  final String pluginId;
  final String title;
  final String version;
  final int contract;
  final Set<String> permissions;
  final String entryPath;
}

/// 诊断页：把日志和插件信息摊在屏幕上，可复制。
///
/// **存在理由**：`debugPrint` 只写 logcat，用户在手机上完全看不见。
/// 2026-11-16 排查插件问题，所有现场只剩"点了没反应"一句话 ——
/// WebView 的 JS 报错、离屏查询返回 unsupported、插件加载失败，全沉在系统日志里。
/// 这里不追求"日志系统"，只求"出问题时能把现场原样贴出来"。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.plugin});

  /// 不为空时只看这一个插件的信息和相关日志。
  final PluginDiagnostics? plugin;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  /// 插件相关日志的 tag。这几个是插件链路上真正会说话的：
  /// `plugin` 打开/加载失败、`query-host` 离屏查询、`bridge` 能力调用。
  static const List<String> _pluginTags = <String>['plugin', 'query-host', 'bridge'];

  late List<AppLogEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _read();
  }

  List<AppLogEntry> _read() {
    final plugin = widget.plugin;
    if (plugin == null) return AppLog.entries;
    // 先按 tag 捞，再补上正文里提到这个插件 id 的行 —— 日志不是每行都带 tag，
    // 只按 tag 过滤会漏掉 "插件打不开：xxx" 这种关键错误。
    final byTag = AppLog.byTags(_pluginTags, limit: AppLog.maxEntries);
    final mentioned = AppLog.entries.where(
      (e) => !byTag.contains(e) && e.message.contains(plugin.pluginId),
    );
    final merged = <AppLogEntry>[...byTag, ...mentioned]
      ..sort((a, b) => a.at.compareTo(b.at));
    return merged.length > 200 ? merged.sublist(merged.length - 200) : merged;
  }

  void _reload() => setState(() => _entries = _read());

  Future<void> _copy() async {
    final text = _buildText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 ${text.split('\n').length} 行'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text('只清内存里的这份，不影响任务和插件数据。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    AppLog.clear();
    _reload();
  }

  String _buildText() {
    final buffer = StringBuffer();
    final plugin = widget.plugin;
    if (plugin != null) {
      buffer.writeln('插件 ${plugin.pluginId}（${plugin.title}）');
      buffer.writeln('版本 ${plugin.version} · 契约 ${plugin.contract}');
      buffer.writeln('权限 ${plugin.permissions.isEmpty ? '无' : plugin.permissions.join(', ')}');
      buffer.writeln('入口 ${plugin.entryPath}');
      buffer.writeln('');
    }
    for (final entry in _entries) {
      buffer.writeln(entry.line);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plugin = widget.plugin;

    return Scaffold(
      appBar: AppBar(
        title: Text(plugin == null ? '诊断与日志' : '插件诊断',
            style: const TextStyle(fontSize: 16)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '复制全部',
            onPressed: _entries.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          if (plugin == null)
            IconButton(
              tooltip: '清空',
              onPressed: _entries.isEmpty ? null : _clear,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        // 底部多留一截：这页是 push 上来的，但 shell 的底栏仍然压在下面
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: <Widget>[
          if (plugin != null) ...<Widget>[
            _InfoCard(plugin: plugin),
            const SizedBox(height: 16),
          ],
          Row(
            children: <Widget>[
              Text('日志 · ${_entries.length} 条',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text('上限 ${AppLog.maxEntries}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 6),
          if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                plugin == null
                    ? '还没有日志。用一会儿再回来看看。'
                    : '这个插件暂时没有相关日志。',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                _entries.map((e) => e.line).join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 静态信息卡：出问题时最常被问到的四个值。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.plugin});

  final PluginDiagnostics plugin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      ('插件 id', plugin.pluginId),
      ('名称', plugin.title),
      ('版本', plugin.version),
      ('契约版本', '${plugin.contract}'),
      ('权限', plugin.permissions.isEmpty ? '未声明' : plugin.permissions.join('、')),
      ('入口', plugin.entryPath),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 68,
                    child: Text(row.$1,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: SelectableText(
                      row.$2,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
