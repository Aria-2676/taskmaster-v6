import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backup/backup_service.dart';
import '../data/backup_repository.dart';
import '../data/download_exporter.dart';
import 'restore_report_page.dart';

/// 备份与还原。
///
/// 页面只做三件事：**建**（选内容）、**管**（列表 / 分享 / 删除）、**恢复**
/// （选内容 → 说清会覆盖什么 → 出报告）。
///
/// 不做"自动备份"：什么时候该备份是用户的事，偷偷写文件比不备份更让人意外。
class BackupPage extends StatefulWidget {
  const BackupPage({
    super.key,
    required this.service,
    required this.repository,
    this.appVersion,
    required this.nameOf,
    this.exporter = const DownloadExporter(),
  });

  final BackupService service;
  final BackupRepository repository;

  /// 写进 manifest 的 App 版本。测试直接给；生产里传 null，首次备份时去问系统。
  final String? appVersion;

  /// 存到系统「下载」目录。抽出来是为了能在测试里替换掉平台通道。
  final DownloadExporter exporter;

  /// 插件 id → 显示名。取不到就显示 id，别显示空白。
  final String Function(String pluginId) nameOf;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  List<BackupFile> _files = const <BackupFile>[];
  List<PluginDataInfo> _plugins = const <PluginDataInfo>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _resolvedVersion;

  /// 版本号只用来在备份文件里留个"哪版打的"，取不到不影响功能
  Future<String> _version() async {
    if (widget.appVersion != null) return widget.appVersion!;
    if (_resolvedVersion != null) return _resolvedVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      return _resolvedVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      return _resolvedVersion = '未知';
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.repository.list();
      final plugins = await widget.service.listPluginData();
      if (!mounted) return;
      setState(() {
        _files = files;
        _plugins = plugins;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  // ── 新建 ────────────────────────────────────────────────────────────

  Future<void> _create() async {
    final pluginsWithData = _plugins.where((info) => info.rowCount > 0).toList();
    final selection = await showModalBottomSheet<_Selection>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SelectionSheet(
        title: '新建备份',
        confirmLabel: '生成备份',
        sections: const <String>['tasks', 'tags', 'settings'],
        allowRecycleBin: true,
        plugins: <_PluginChoice>[
          for (final info in pluginsWithData)
            _PluginChoice(
              id: info.pluginId,
              label: widget.nameOf(info.pluginId),
              detail: '${info.rowCount} 条数据',
              // **已装默认勾、已卸载默认不勾**：卸载时用户已经决定不要它了，
              // 默认带上会让备份范围和恢复范围悄悄变大。
              selectedByDefault: info.installed,
              note: info.installed ? null : '已卸载，数据还在',
            ),
        ],
      ),
    );
    if (selection == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final data = await widget.service.collect(
        appVersion: await _version(),
        tasks: selection.sections.contains('tasks'),
        tags: selection.sections.contains('tags'),
        settings: selection.sections.contains('settings'),
        recycleBin: selection.sections.contains('recycleBin'),
        pluginIds: selection.plugins,
      );
      final bytes = widget.service.pack(data);
      await widget.repository.save(bytes, manifest: data.manifest);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      _toast('已备份 · ${data.manifest.summary}');
    } catch (error) {
      if (!mounted) return;
      _toast('备份失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 恢复 ────────────────────────────────────────────────────────────

  Future<void> _restore(BackupFile file) async {
    setState(() => _busy = true);
    try {
      final BackupData data;
      try {
        data = widget.service.unpack(await File(file.path).readAsBytes());
      } on BackupException catch (error) {
        if (!mounted) return;
        _toast(error.message);
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }

      if (!mounted) return;
      // 备份里有的插件，当前**有没有表**决定了它能不能恢复
      final currentIds = <String>{
        for (final info in _plugins)
          if (info.tableCount > 0 || info.rowCount > 0) info.pluginId,
      };
      final selection = await showModalBottomSheet<_Selection>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _SelectionSheet(
          title: '恢复「${file.timeLabel}」',
          confirmLabel: '下一步',
          sections: const <String>['tasks', 'tags', 'settings'],
          allowRecycleBin: data.recycled.isNotEmpty,
          plugins: <_PluginChoice>[
            for (final entry in data.plugins.entries)
              _PluginChoice(
                id: entry.key,
                label: widget.nameOf(entry.key),
                detail: '备份里有 ${entry.value.rowCount} 条',
                selectedByDefault:
                    currentIds.contains(entry.key) && (file.manifest.counts['plugin:${entry.key}'] ?? 0) > 0,
                enabled: currentIds.contains(entry.key),
                note: currentIds.contains(entry.key)
                    ? null
                    : (data.plugins[entry.key]?.tables.isEmpty ?? true
                        ? '备份里只有设置，没有表'
                        : '当前没有这个插件的数据表，先装上再来'),
              ),
          ],
        ),
      );
      if (selection == null || !mounted) return;

      final confirmed = await _confirmRestore(data, selection);
      if (confirmed != true || !mounted) return;

      setState(() => _busy = true);
      final report = await widget.service.restore(
        data,
        tasks: selection.sections.contains('tasks'),
        tags: selection.sections.contains('tags'),
        settings: selection.sections.contains('settings'),
        recycleBin: selection.sections.contains('recycleBin'),
        pluginIds: selection.plugins,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _showReport(report);
      if (mounted) await _reload();
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  /// 二次确认要写**具体数字**：只说"确定吗"等于让用户闭眼点。
  Future<bool?> _confirmRestore(BackupData data, _Selection selection) {
    final counts = data.manifest.counts;
    final lines = restoreConfirmLines(
      data,
      tasks: selection.sections.contains('tasks'),
      tags: selection.sections.contains('tags'),
      settings: selection.sections.contains('settings'),
      recycleBin: selection.sections.contains('recycleBin'),
      pluginIds: selection.plugins,
      nameOf: widget.nameOf,
    );

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复？', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('会覆盖当前数据，且没有撤销。', style: TextStyle(fontSize: 13.5)),
            const SizedBox(height: 10),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text('· $line',
                    style: const TextStyle(fontSize: 12.5, height: 1.35)),
              ),
            if (counts.isEmpty) const SizedBox.shrink(),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('覆盖恢复'),
          ),
        ],
      ),
    );
  }

  Future<void> _showReport(RestoreReport report) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RestoreReportPage(report: report)),
    );
  }

  // ── 分享 / 删除 ─────────────────────────────────────────────────────

  Future<void> _share(BackupFile file) async {
    try {
      await SharePlus.instance.share(ShareParams(
        files: <XFile>[XFile(file.path)],
        subject: file.name,
        // 备份里有任务正文，属敏感数据；提示一句，用户才知道发给了谁
        text: '任务管家 v6 备份（含全部任务正文，请确认发给谁）',
      ));
    } catch (error) {
      if (mounted) _toast('分享失败：$error');
    }
  }

  /// 超过保留上限时，把最早的那些删掉。
  ///
  /// 只删到上限为止（`over` 就是多出来的那几份），**不自动执行** ——
  /// 备份是用户的退路，删之前必须他自己点一次，并且知道删的是哪几份。
  Future<void> _trimOldest(List<BackupFile> over) async {
    final oldest = over.last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除较早的备份？', style: TextStyle(fontSize: 16)),
        content: Text(
          '将删除 ${over.length} 份，最早的一份是 ${oldest.timeLabel}。\n'
          '删掉之后找不回来 —— 想留着就先点那一行的「分享」存到别处。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      for (final file in over) {
        await widget.repository.delete(file);
      }
      await _reload();
      if (mounted) _toast('已删除 ${over.length} 份较早的备份');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 存一份到系统的「下载/任务管家」。
  ///
  /// 和「分享」是两条路：分享是把文件交给别的 App（微信、网盘），
  /// 这个是留在自己手机上、插上电脑就能拷走。用户明确要过后者。
  Future<void> _saveToDownloads(BackupFile file) async {
    try {
      final saved = await widget.exporter.saveToDownloads(path: file.path, name: file.name);
      if (mounted) _toast('已存到 $saved');
    } catch (error) {
      // 原生给的原文直接露出来（"打不开写入流""建不了目录"都在这句里）
      if (mounted) _toast('存不进去：$error');
    }
  }

  Future<void> _delete(BackupFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这份备份？', style: TextStyle(fontSize: 16)),
        content: Text('${file.timeLabel} · ${file.manifest.summary}\n删掉之后找不回来。',
            style: const TextStyle(fontSize: 13)),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.repository.delete(file);
    if (!mounted) return;
    await _reload();
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final over = widget.repository.overLimit(_files);

    return Scaffold(
      appBar: AppBar(
        title: const Text('备份与还原', style: TextStyle(fontSize: 16)),
        centerTitle: true,
        actions: <Widget>[
          IconButton(
            tooltip: '新建备份',
            onPressed: _busy || _loading ? null : _create,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: <Widget>[
                if (_error != null)
                  _Card(children: <Widget>[
                    Text('备份目录读不出来：$_error',
                        style: TextStyle(fontSize: 12.5, color: scheme.error)),
                  ]),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (over.isNotEmpty)
                  _Card(children: <Widget>[
                    Text(
                      '已有 ${_files.length} 份备份，超过 $BackupRepository.keepLimit 份了。'
                      '建议删掉较早的 —— 或者分享出去存到别处。',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : () => _trimOldest(over),
                        child: Text('删掉最早的 ${over.length} 份',
                            style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                  ]),
                _Card(children: <Widget>[
                  Text(
                    '备份是一个文件，里面有任务、标签和设置。'
                    '想放到别处就点某一份的「分享」——它和普通文件一样，'
                    '能存网盘、发给自己。',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.45),
                  ),
                ]),
                const SizedBox(height: 4),
                if (_files.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 28),
                    child: Column(
                      children: <Widget>[
                        Icon(Icons.inventory_2_outlined, size: 34, color: scheme.outline),
                        const SizedBox(height: 10),
                        Text('还没有备份', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text('右上角的 + 生成第一份',
                            style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                      ],
                    ),
                  )
                else
                  for (final file in _files) ...<Widget>[
                    _BackupTile(
                      file: file,
                      busy: _busy,
                      onRestore: () => _restore(file),
                      onShare: () => _share(file),
                      onSaveToDownloads: () => _saveToDownloads(file),
                      onDelete: () => _delete(file),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }
}

class _BackupTile extends StatelessWidget {
  const _BackupTile({
    required this.file,
    required this.busy,
    required this.onRestore,
    required this.onShare,
    required this.onSaveToDownloads,
    required this.onDelete,
  });

  final BackupFile file;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onShare;
  final VoidCallback onSaveToDownloads;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(file.timeLabel, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 3),
                Text(
                  '${file.manifest.summary} · ${file.sizeLabel}',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRestore,
            child: const Text('恢复', style: TextStyle(fontSize: 13)),
          ),
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (value) {
              if (value == 'share') onShare();
              if (value == 'download') onSaveToDownloads();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'share', child: Text('分享 / 存到别处', style: TextStyle(fontSize: 13))),
              PopupMenuItem<String>(
                value: 'download',
                child: Text('存到「下载」', style: TextStyle(fontSize: 13)),
              ),
              PopupMenuItem<String>(value: 'delete', child: Text('删除', style: TextStyle(fontSize: 13))),
            ],
          ),
        ],
      ),
    ]);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ),
    );
  }
}

// ── 勾选面板 ──────────────────────────────────────────────────────────

class _PluginChoice {
  const _PluginChoice({
    required this.id,
    required this.label,
    required this.detail,
    required this.selectedByDefault,
    this.enabled = true,
    this.note,
  });

  final String id;
  final String label;
  final String detail;
  final bool selectedByDefault;
  final bool enabled;
  final String? note;
}

class _Selection {
  const _Selection(this.sections, this.plugins);
  final Set<String> sections;
  final Set<String> plugins;
}

class _SelectionSheet extends StatefulWidget {
  const _SelectionSheet({
    required this.title,
    required this.confirmLabel,
    required this.sections,
    required this.plugins,
    this.allowRecycleBin = false,
  });

  final String title;
  final String confirmLabel;
  final List<String> sections;
  final List<_PluginChoice> plugins;
  final bool allowRecycleBin;

  @override
  State<_SelectionSheet> createState() => _SelectionSheetState();
}

class _SelectionSheetState extends State<_SelectionSheet> {
  late final Set<String> _sections = <String>{...widget.sections};
  late final Set<String> _plugins = <String>{
    for (final choice in widget.plugins)
      if (choice.selectedByDefault && choice.enabled) choice.id,
  };
  bool _recycleBin = false;

  static const Map<String, String> _sectionLabels = <String, String>{
    'tasks': '任务',
    'tags': '标签',
    'settings': '设置',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skippedLeftovers = widget.plugins
        .where((c) => !c.enabled ? false : (c.note != null && !_plugins.contains(c.id)))
        .length;

    // 高度取**父约束的 70%**，不用 MediaQuery。
    //
    // 踩过的坑：`MediaQuery.sizeOf(context).height` 在这个弹层里给的是 1820，
    // 而视口只有 800 —— 于是"屏幕 70%"算成 1274，确认按钮正好落在 y=1274，
    // 屏幕外，点不到。FractionallySizedBox 用的是**传进来的约束**，
    // 在弹层里那就是视口高度，不会算错。
    return FractionallySizedBox(
      heightFactor: 0.7,
        child: SafeArea(
        child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.title, style: const TextStyle(fontSize: 15)),
              ),
            ),
            // **不能是 ListView(shrinkWrap: true)**：它会按内容高度撑开，
            // 忽略 Flexible 给的剩余空间 —— 内容一多就顶破弹层，底部的确认按钮
            // 落到屏幕外，用户点不到（测试里的表现是 tap 落空、落点 y 超过屏高）。
            // SingleChildScrollView 才是"内容小就贴着，内容大就滚"。
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                  for (final section in widget.sections)
                    CheckboxListTile(
                      dense: true,
                      value: _sections.contains(section),
                      title: Text(_sectionLabels[section] ?? section,
                          style: const TextStyle(fontSize: 14)),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _sections.add(section);
                        } else {
                          _sections.remove(section);
                        }
                      }),
                    ),
                  if (widget.allowRecycleBin)
                    CheckboxListTile(
                      dense: true,
                      value: _recycleBin,
                      title: const Text('回收站', style: TextStyle(fontSize: 14)),
                      onChanged: (value) => setState(() => _recycleBin = value ?? false),
                    ),
                  if (widget.plugins.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                      child: Text('插件数据',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                    for (final choice in widget.plugins)
                      CheckboxListTile(
                        dense: true,
                        value: _plugins.contains(choice.id),
                        title: Text(choice.label, style: const TextStyle(fontSize: 14)),
                        subtitle: Text(
                          [choice.detail, if (choice.note != null) choice.note!].join(' · '),
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                        onChanged: choice.enabled
                            ? (value) => setState(() {
                                  if (value == true) {
                                    _plugins.add(choice.id);
                                  } else {
                                    _plugins.remove(choice.id);
                                  }
                                })
                            : null,
                      ),
                  ],
                  if (skippedLeftovers > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        '有 $skippedLeftovers 个插件的遗留数据没选（它们已经卸载，数据还在）',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 确认按钮放**底部**。放头部时，插件一多就把头部挤出屏幕，
            // 用户永远点不到（测试里的表现是 tap 落空、落点在屏幕外）。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    _Selection(<String>{..._sections, if (_recycleBin) 'recycleBin'}, _plugins),
                  ),
                  child: Text(widget.confirmLabel),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 恢复确认框里要写的每一行。
///
/// 抽成纯函数是为了能直接测"有没有写具体条数"——通过弹层去断言的话，
/// 测的其实是弹层的布局能不能点到按钮，跑起来还慢。
@visibleForTesting
List<String> restoreConfirmLines(
  BackupData data, {
  required bool tasks,
  required bool tags,
  required bool settings,
  required bool recycleBin,
  required Set<String> pluginIds,
  required String Function(String id) nameOf,
}) =>
    <String>[
      if (tasks) '任务 → 备份里有 ${data.tasks.length} 条，会覆盖当前全部任务',
      if (tags) '标签 → 备份里有 ${data.tags.length} 个，会覆盖当前全部标签与关联',
      if (settings) '设置 → 恢复 ${data.settings.length} 项（只覆盖备份里有的键）',
      if (recycleBin) '回收站 → ${data.recycled.length} 条',
      for (final id in pluginIds) '${nameOf(id)} → ${data.plugins[id]?.rowCount ?? 0} 条数据',
    ];
