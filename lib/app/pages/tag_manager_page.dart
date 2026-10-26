import 'package:flutter/material.dart';

import '../models/task.dart';
import '../state/task_store.dart';

/// 标签管理。
///
/// 主包内功能，不是插件：标签是任务的基础维度，插件只会在插槽里**读**它，
/// 不会替换它（"插件不能提供主包没有的东西"这条判据）。
///
/// 这里只管标签本身的增删改；给任务打标签在新建任务时做，
/// 任务级编辑（改标题/改标签）还没做。
class TagManagerPage extends StatefulWidget {
  const TagManagerPage({super.key, required this.store});

  final TaskStore store;

  @override
  State<TagManagerPage> createState() => _TagManagerPageState();
}

class _TagManagerPageState extends State<TagManagerPage> {
  /// 每个标签被多少任务使用。不放进 TaskStore：它只在管理页用得上，
  /// 每次改动后重新查一遍，避免"改完标签数量还显示旧值"。
  Map<int, int> _usage = const <int, int>{};

  @override
  void initState() {
    super.initState();
    _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    final usage = await widget.store.tagUsage();
    if (!mounted) return;
    setState(() => _usage = usage);
  }

  Future<void> _edit(Tag? tag) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TagEditDialog(
        tag: tag,
        onSubmit: (name, color) async {
          try {
            if (tag == null) {
              await widget.store.addTag(name, color);
            } else {
              await widget.store.renameTag(tag, name);
              if (color != tag.color) await widget.store.setTagColor(tag, color);
            }
            return null;
          } on TagException catch (error) {
            return error.message;
          }
        },
      ),
    );
    if (saved == true) await _refreshUsage();
  }

  Future<void> _delete(Tag tag) async {
    final used = _usage[tag.id] ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签', style: TextStyle(fontSize: 16)),
        content: Text(
          used == 0
              ? '「${tag.name}」还没被任何任务使用。'
              : '有 $used 个任务正在使用「${tag.name}」，删除后它们会失去这个标签。'
                  '任务本身不会被删除。',
          style: const TextStyle(fontSize: 13.5),
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
    if (confirmed != true) return;

    await widget.store.deleteTag(tag);
    await _refreshUsage();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('已删除「${tag.name}」'), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('标签管理', style: TextStyle(fontSize: 16)),
        actions: <Widget>[
          IconButton(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add),
            tooltip: '新建标签',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final tags = widget.store.tags;
          if (tags.isEmpty) return _buildEmpty(scheme);

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
            itemCount: tags.length,
            itemBuilder: (context, i) => _buildRow(scheme, tags[i]),
          );
        },
      ),
    );
  }

  Widget _buildRow(ColorScheme scheme, Tag tag) {
    final used = _usage[tag.id] ?? 0;

    // 用 Material 而不是"Container + BoxDecoration"：ListTile 的水波纹画在最近的
    // Material 上，中间隔一层带背景色的 DecoratedBox 会被断言拦下（也确实会看不见）。
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        child: ListTile(
        dense: true,
        onTap: () => _edit(tag),
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: tag.displayColor, shape: BoxShape.circle),
        ),
        title: Text(tag.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          used == 0 ? '未使用' : '$used 个任务',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
          trailing: IconButton(
            onPressed: () => _delete(tag),
            icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
            visualDensity: VisualDensity.compact,
            tooltip: '删除标签',
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.sell_outlined, size: 34, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text('还没有标签', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            '右上角新建，建完可以在新建任务时选',
            style: TextStyle(fontSize: 11.5, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 新建 / 编辑标签。
///
/// 校验放在 [onSubmit] 里由调用方做：这样"重名"之类的错误能显示在输入框下面，
/// 而不是关掉弹窗、再弹一条 SnackBar 让用户重填。
class _TagEditDialog extends StatefulWidget {
  const _TagEditDialog({required this.tag, required this.onSubmit});

  final Tag? tag;

  /// 返回 null 表示保存成功；返回字符串表示失败原因
  final Future<String?> Function(String name, String color) onSubmit;

  @override
  State<_TagEditDialog> createState() => _TagEditDialogState();
}

class _TagEditDialogState extends State<_TagEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.tag?.name ?? '');
  late String _color = widget.tag?.color ?? _palette.first;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final error = await widget.onSubmit(_controller.text, _color);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNew = widget.tag == null;

    return AlertDialog(
      title: Text(isNew ? '新建标签' : '编辑标签', style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: '标签名',
              errorText: _error,
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              for (final color in _palette)
                GestureDetector(
                  onTap: () => setState(() => _color = color),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: _parse(color),
                      shape: BoxShape.circle,
                      border: _color == color
                          ? Border.all(color: scheme.onSurface, width: 2)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _submit,
          child: Text(isNew ? '新建' : '保存'),
        ),
      ],
    );
  }

  static Color _parse(String hex) {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return value == null ? const Color(0xFF2196F3) : Color(0xFF000000 | value);
  }
}

/// 可选颜色。固定色板而不是取色器：标签是**分类标记**，
/// 颜色少一点更容易形成习惯，也不会出现两个几乎一样的色。
const List<String> _palette = <String>[
  '#2196F3',
  '#E53935',
  '#FB8C00',
  '#FDD835',
  '#43A047',
  '#00897B',
  '#8E24AA',
  '#757575',
];
