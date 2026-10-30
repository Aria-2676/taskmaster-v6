import 'package:flutter/material.dart';

import '../models/calendar_strip_style.dart';
import '../models/editor_form.dart';
import '../shell/destinations.dart';
import '../state/task_store.dart';

/// 设置页：**只放"怎么工作"**，不放内容浏览和任务操作。
///
/// 分组固定为 外观 / 任务 / 插件 / 数据 / 关于。「数据」组由备份功能（S2）填，
/// 现在不存在 —— **宁可不显示，也不放一个灰的占位项**：用户看到一个点不动的
/// 入口，第一反应是"这 App 坏了"，而不是"这功能还没做"。
///
/// 这里不自己持有状态：日历条形态住在主壳里（首页要跟着变），保留时长要弹
/// "会立刻删几条"的确认框（那个逻辑在主壳）。设置页只负责呈现与转发。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.calendarStyle,
    required this.onCalendarStyleChanged,
    required this.onRetentionDaysChanged,
    required this.onOpenDestination,
    this.pluginSummary,
    this.onOpenBackup,
    this.onDownloadLegacy,
  });

  final TaskStore store;

  final CalendarStripStyle calendarStyle;
  final ValueChanged<CalendarStripStyle> onCalendarStyleChanged;

  /// 改保留时长。主壳那边带"缩短会立刻删几条"的确认与清理，
  /// 所以这里只转发 —— 两处各写一份迟早不一致。
  final ValueChanged<int> onRetentionDaysChanged;

  /// 「插件」「任务」两组里的入口，复用主壳的分发表
  final ValueChanged<AppDestination> onOpenDestination;

  /// 「插件」组右侧的概况文字，比如「已装 2 · 启用 1」
  final String? pluginSummary;

  /// 备份与还原。为 null 时整组不显示（见 [backupPageBuilder] 的注释）
  final VoidCallback? onOpenBackup;

  /// 下载旧版（V5）。两个 App 包名不同、能共存，所以这条是"留个回去的门"，
  /// 不是"降级"。为 null 时整行不显示。
  final VoidCallback? onDownloadLegacy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontSize: 16)),
        centerTitle: true,
      ),
      // **必须监听 store**：这页是 StatelessWidget，拨开关时 store 会 notify，
      // 不监听的话界面纹丝不动（数据变了但看不见）——真机上就是这么发现的：
      // 拨了"先进回收站"，下面的"保留时长"始终不出现。
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          _SectionLabel('外观'),
          _Card(children: <Widget>[
            _SegmentedRow<CalendarStripStyle>(
              title: '日历条形态',
              values: CalendarStripStyle.values,
              selected: calendarStyle,
              labelOf: (style) => style.label,
              onChanged: onCalendarStyleChanged,
            ),
            const Divider(height: 20),
            _SegmentedRow<EditorForm>(
              title: '编辑页形态',
              values: EditorForm.values,
              selected: store.editorForm,
              labelOf: (form) => form.label,
              onChanged: store.setEditorForm,
            ),
          ]),

          _SectionLabel('任务'),
          _Card(children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('删除前确认', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                store.confirmBeforeDelete
                    ? '左滑删除前会问一次'
                    : (store.recycleBinEnabled
                        ? '左滑直接移入回收站'
                        : '左滑直接删除，不问、不可恢复'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              value: store.confirmBeforeDelete,
              onChanged: store.setConfirmBeforeDelete,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('删除后先进回收站', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                store.recycleBinEnabled
                    ? '${store.retentionDays} 天后自动彻底删除，期间可恢复'
                    : '关闭时左滑删除即彻底删掉，无法恢复',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              value: store.recycleBinEnabled,
              onChanged: store.setRecycleBinEnabled,
            ),
            if (store.recycleBinEnabled) ...<Widget>[
              const Divider(height: 20),
              _SegmentedRow<int>(
                title: '保留时长',
                values: const <int>[1, 3, 7, 30],
                selected: _nearestRetention(store.retentionDays),
                labelOf: (days) => '$days 天',
                onChanged: onRetentionDaysChanged,
              ),
            ],
            const Divider(height: 20),
            _LinkRow(
              icon: Icons.tune,
              title: '字段管理',
              subtitle: '有哪些字段、谁在前、默认值',
              onTap: () => onOpenDestination(AppDestination.fieldManager),
            ),
            const Divider(height: 20),
            _LinkRow(
              icon: Icons.inbox_outlined,
              title: '回收站',
              subtitle: '恢复误删的任务',
              onTap: () => onOpenDestination(AppDestination.recycleBin),
            ),
          ]),

          _SectionLabel('插件'),
          _Card(children: <Widget>[
            _LinkRow(
              icon: Icons.extension_outlined,
              title: '插件市场',
              subtitle: pluginSummary ?? '装、升级、停用插件',
              onTap: () => onOpenDestination(AppDestination.pluginMarket),
            ),
            const Divider(height: 20),
            _LinkRow(
              icon: Icons.dashboard_outlined,
              title: '首页模式',
              subtitle: '首页用内置视图，还是换成一整页插件',
              onTap: () => onOpenDestination(AppDestination.homeMode),
            ),
          ]),

          if (onOpenBackup != null) ...<Widget>[
            _SectionLabel('数据'),
            _Card(children: <Widget>[
              _LinkRow(
                icon: Icons.inventory_2_outlined,
                title: '备份与还原',
                subtitle: '任务、标签、设置，以及每个插件的数据单独选',
                onTap: onOpenBackup!,
              ),
            ]),
          ],

          _SectionLabel('关于'),
          _Card(children: <Widget>[
            if (onDownloadLegacy != null)
              _LinkRow(
                icon: Icons.history,
                title: '下载旧版（V5）',
                subtitle: '想回旧版随时可以，两个 App 能共存',
                onTap: onDownloadLegacy!,
              ),
            _LinkRow(
              icon: Icons.info_outline,
              title: '版本与更新',
              subtitle: '查看版本号、检查新版本',
              onTap: () => onOpenDestination(AppDestination.about),
            ),
          ]),
        ],
        ),
      ),
    );
  }

  /// 存量值不在档位里时取最接近的一档 —— 否则 SegmentedButton 会断言失败。
  int _nearestRetention(int days) => const <int>[1, 3, 7, 30].reduce(
        (a, b) => (a - days).abs() <= (b - days).abs() ? a : b,
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // **必须用 Material 而不是带背景色的 Container**：里面装着 SwitchListTile，
    // 它把背景和水波纹画在最近的 Material 上；中间隔一个 DecoratedBox 会把这个
    // 覆盖掉，Flutter 直接断言 "ink splashes may be invisible"（测试里就炸了）。
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    required this.title,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    // **标题在上、分段在下**，不要挤在一行：卡片内宽只有 300pt 左右，
    // "保留时长"四个档位（1/3/7/30 天）放在标题右边会直接 RenderFlex overflow。
    // 上下排布后各档位有整行宽度，窄屏也不会炸。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<T>(
              segments: values
                  .map((value) => ButtonSegment<T>(
                        value: value,
                        label: Text(labelOf(value)),
                      ))
                  .toList(),
              selected: <T>{selected},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}
