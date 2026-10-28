import 'package:flutter/material.dart';

import '../models/calendar_strip_style.dart';
import '../models/editor_form.dart';
import 'destinations.dart';

/// 「我的」页。两块内容：
///   1. 设置项（日历条形态、删除确认）—— 内联控件
///   2. 入口清单 —— 与侧边栏**同源**（[AppDestination]），只是带右箭头
class ProfileStubPage extends StatelessWidget {
  const ProfileStubPage({
    super.key,
    required this.currencyLabel,
    required this.calendarStyle,
    required this.onCalendarStyleChanged,
    required this.editorForm,
    required this.onEditorFormChanged,
    required this.confirmBeforeDelete,
    required this.onConfirmBeforeDeleteChanged,
    required this.recycleBinEnabled,
    required this.onRecycleBinChanged,
    required this.retentionDays,
    required this.onRetentionDaysChanged,
    required this.onOpenDestination,
  });

  /// 顶部那行货币文案（由主壳算好，这里不碰状态）
  final String currencyLabel;

  final CalendarStripStyle calendarStyle;
  final ValueChanged<CalendarStripStyle> onCalendarStyleChanged;

  /// 编辑页形态：底部弹层 / 全屏
  final EditorForm editorForm;
  final ValueChanged<EditorForm> onEditorFormChanged;

  /// 删除前是否弹确认框（对应"以后不再提醒"那个勾选）
  final bool confirmBeforeDelete;
  final ValueChanged<bool> onConfirmBeforeDeleteChanged;

  /// 删除后先进回收站（默认关）
  final bool recycleBinEnabled;
  final ValueChanged<bool> onRecycleBinChanged;

  /// 回收站保留天数
  final int retentionDays;
  final ValueChanged<int> onRetentionDaysChanged;

  final ValueChanged<AppDestination> onOpenDestination;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.bolt, size: 20, color: scheme.outline),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  currencyLabel,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('外观', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            const Expanded(child: Text('日历条形态', style: TextStyle(fontSize: 14))),
            SegmentedButton<CalendarStripStyle>(
              segments: CalendarStripStyle.values
                  .map((s) => ButtonSegment<CalendarStripStyle>(value: s, label: Text(s.label)))
                  .toList(),
              selected: <CalendarStripStyle>{calendarStyle},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (selection) => onCalendarStyleChanged(selection.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Expanded(child: Text('编辑页形态', style: TextStyle(fontSize: 14))),
            SegmentedButton<EditorForm>(
              segments: EditorForm.values
                  .map((f) => ButtonSegment<EditorForm>(value: f, label: Text(f.label)))
                  .toList(),
              selected: <EditorForm>{editorForm},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (selection) => onEditorFormChanged(selection.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 4),
        Text('操作', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('删除前确认', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            confirmBeforeDelete
                ? '左滑删除前会问一次'
                : (recycleBinEnabled ? '左滑直接移入回收站' : '左滑直接删除，不问、不可恢复'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          value: confirmBeforeDelete,
          onChanged: onConfirmBeforeDeleteChanged,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('删除后先进回收站', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            recycleBinEnabled
                ? '$retentionDays 天后自动彻底删除，期间可恢复'
                : '关闭时左滑删除即彻底删掉，无法恢复',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          value: recycleBinEnabled,
          onChanged: onRecycleBinChanged,
        ),
        if (recycleBinEnabled) ...<Widget>[
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('保留时长', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
              SegmentedButton<int>(
                segments: const <int>[1, 3, 7, 30]
                    .map((d) => ButtonSegment<int>(value: d, label: Text('$d 天')))
                    .toList(),
                selected: <int>{
                  // 存量值不在档位里时，显示最接近的一档，避免 SegmentedButton 断言
                  <int>[1, 3, 7, 30].reduce(
                    (a, b) => (a - retentionDays).abs() <= (b - retentionDays).abs() ? a : b,
                  ),
                },
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (selection) => onRetentionDaysChanged(selection.first),
              ),
            ],
          ),
        ],
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 4),
        Text('入口', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        for (final destination in AppDestination.values
            .where((d) => d.surfaces.contains(DestinationSurface.profile)))
          DestinationTile(
            destination: destination,
            showChevron: true,
            onTap: () => onOpenDestination(destination),
          ),
      ],
    );
  }
}
