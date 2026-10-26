import 'package:flutter/material.dart';

import '../../core/home/home_mode.dart';
import '../../core/plugin/plugin_store.dart';
import '../state/home_mode_store.dart';

/// 一个可选的首页形态。`pluginId == null` 表示内置任务模式。
///
/// 抽出来是因为**两个地方要列同一份东西**：顶栏的快捷切换器，和设置里的
/// 「首页模式」页。两处各写一遍，迟早出现"这里能选、那里选不了"。
class ModeOption {
  const ModeOption({
    required this.pluginId,
    required this.name,
    required this.subtitle,
  });

  final String? pluginId;
  final String name;
  final String subtitle;

  bool get isBuiltin => pluginId == null;

  HomeMode get mode =>
      pluginId == null ? const HomeMode.builtin() : HomeMode.plugin(pluginId!);
}

/// 可选模式清单：内置 + 所有已装插件。
///
/// **不区分"这个插件是不是模式插件"** —— 插件没有类别声明，主包判断不了。
/// 一律列出来，由用户决定拿哪个当首页；装了个使用说明插件也能选，
/// 后果只是首页变成一页说明，随时能切回来。
List<ModeOption> buildModeOptions({
  required List<InstalledPlugin> plugins,
  required String Function(String pluginId) nameOf,
}) {
  return <ModeOption>[
    const ModeOption(
      pluginId: null,
      name: '任务模式',
      subtitle: '按天排列的任务 + 日历条',
    ),
    for (final plugin in plugins)
      ModeOption(
        pluginId: plugin.pluginId,
        name: nameOf(plugin.pluginId),
        subtitle: '插件整页 · v${plugin.version}',
      ),
  ];
}

/// 顶栏用的快捷切换器：底部弹层，点一下就是切。
///
/// 和设置里的「首页模式」页不是重复功能：那页负责解释与失败告警，
/// 这个只负责"随手换一个"。真正写状态的都走 [HomeModeStore.setMode]。
Future<void> showModeSwitcher(
  BuildContext context, {
  required HomeModeStore store,
  required List<InstalledPlugin> plugins,
  required String Function(String pluginId) nameOf,
  VoidCallback? onOpenManager,
}) {
  final options = buildModeOptions(plugins: plugins, nameOf: nameOf);

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    '当前模式',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final option in options)
                  ModeTile(
                    option: option,
                    selected: store.mode == option.mode,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      store.setMode(option.mode);
                    },
                  ),
                if (onOpenManager != null) ...<Widget>[
                  Divider(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                    height: 8,
                  ),
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.tune, size: 18, color: scheme.outline),
                    title: Text(
                      '管理模式',
                      style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onOpenManager();
                    },
                  ),
                ],
              ],
            );
          },
        ),
      );
    },
  );
}

class ModeTile extends StatelessWidget {
  const ModeTile({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ModeOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(
        option.isBuiltin ? Icons.checklist_rtl : Icons.extension_outlined,
        size: 20,
        color: selected ? scheme.primary : scheme.outline,
      ),
      title: Text(
        option.name,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? scheme.primary : scheme.onSurface,
        ),
      ),
      subtitle: Text(
        option.subtitle,
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      ),
      trailing: selected
          ? Icon(Icons.check, size: 18, color: scheme.primary)
          : null,
    );
  }
}
