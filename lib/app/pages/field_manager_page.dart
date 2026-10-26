import 'package:flutter/material.dart';

import '../../core/field/task_field.dart';
import '../state/field_store.dart';

/// 字段管理：**排序 + 开关 + 默认值**。
///
/// 这一页是"编辑页自定义"的全部入口，不需要装任何插件。
/// 关掉一个字段只是不画它，**任务里的内容不会删** —— 页面上要写明这一点，
/// 否则用户会以为关开关等于清数据。
class FieldManagerPage extends StatelessWidget {
  const FieldManagerPage({super.key, required this.store});

  final FieldStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('字段管理', style: TextStyle(fontSize: 16)),
        actions: <Widget>[
          TextButton(
            onPressed: () => _confirmReset(context),
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final fields = store.ordered;
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.info_outline, size: 13, color: scheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '关闭只是不显示，任务里已有的内容不会删。长按拖动可以调顺序。',
                        style: TextStyle(fontSize: 11.5, height: 1.35, color: scheme.outline),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: fields.length,
                  onReorder: (oldIndex, newIndex) => store.reorder(oldIndex, newIndex),
                  itemBuilder: (context, index) {
                    final field = fields[index];
                    return _FieldTile(
                      key: ValueKey<String>(field.id),
                      field: field,
                      store: store,
                      index: index,
                      scheme: scheme,
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认字段设置', style: TextStyle(fontSize: 16)),
        content: const Text(
          '顺序、开关、默认值都会回到出厂状态。任务数据不受影响。',
          style: TextStyle(fontSize: 13.5),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    await store.reset();
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    super.key,
    required this.field,
    required this.store,
    required this.index,
    required this.scheme,
  });

  final TaskField field;
  final FieldStore store;
  final int index;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final visible = !store.isHidden(field.id);
    final defaultValue = store.defaultOf(field);

    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: field.defaultEditable ? () => _editDefault(context) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(field.label, style: const TextStyle(fontSize: 14)),
                        if (field.locked) ...<Widget>[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Text(
                              '核心',
                              style: TextStyle(fontSize: 9.5, color: scheme.outline),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (field.defaultEditable)
                      Text(
                        '默认：${_optionLabel(field, defaultValue)}',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      )
                    else if (field.hint != null)
                      Text(
                        field.hint!,
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (field.locked)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('必填', style: TextStyle(fontSize: 11, color: scheme.outline)),
                )
              else
                Switch(
                  value: visible,
                  onChanged: (value) => store.setVisible(field.id, value),
                ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.drag_handle, size: 20, color: scheme.outlineVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editDefault(BuildContext context) async {
    final picked = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '新建任务时的默认${field.label}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            for (final option in field.options)
              RadioListTile<String>(
                dense: true,
                value: option.value,
                // 当前生效的默认值。null（=不设）要落到「不设」那一档上，
                // 否则打开弹层时一个都没选中，用户不知道现在的默认是什么。
                groupValue: store.defaultOf(field) ??
                    (field.options.any((o) => o.isNone) ? '' : null),
                title: Text(option.label, style: const TextStyle(fontSize: 14)),
                onChanged: (value) => Navigator.of(ctx).pop(value),
              ),
            if (store.prefs.defaults.containsKey(field.id))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(_clearMarker),
                  child: Text('恢复字段自带默认（${_optionLabel(field, field.defaultValue)}）'),
                ),
              ),
          ],
        ),
      ),
    );

    if (picked == null) return;
    await store.setDefault(field.id, picked == _clearMarker ? null : picked);
  }

  /// 用不可能出现在档位里的值表示"清掉覆盖"
  static const String _clearMarker = '__reset__';

  static String _optionLabel(TaskField field, String? value) {
    if (value == null) return '不设';
    for (final option in field.options) {
      if (option.value == value) return option.label;
    }
    return value;
  }
}
