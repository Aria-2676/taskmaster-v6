import 'package:flutter/material.dart';

import '../../core/plugin/plugin_store.dart';
import 'destinations.dart';

/// 半屏侧边栏。入口全部来自 [AppDestination]（与「我的」页同源），
/// 已装插件追加在「插件市场」之后。
class SideNav extends StatelessWidget {
  const SideNav({
    super.key,
    required this.currentTab,
    required this.onOpenDestination,
    this.installedPlugins = const <InstalledPlugin>[],
    this.onOpenPlugin,
    this.pluginNameOf,
  });

  final int currentTab;
  final ValueChanged<AppDestination> onOpenDestination;

  /// 已安装插件 —— 它们的入口排在「插件市场」下面
  final List<InstalledPlugin> installedPlugins;
  final ValueChanged<InstalledPlugin>? onOpenPlugin;
  final String Function(String pluginId)? pluginNameOf;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drawerItems = AppDestination.values
        .where((d) => d.surfaces.contains(DestinationSurface.drawer))
        .toList();
    final mainItems = drawerItems.where((d) => !d.isFooter);
    final footerItems = drawerItems.where((d) => d.isFooter);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('任务管家',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('v6 预览',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          for (final destination in mainItems)
            DestinationTile(
              destination: destination,
              selected: destination == AppDestination.todayTasks && currentTab == 0,
              // 关抽屉是**侧边栏自己的事**：MainShell 不 pop，
              // 否则从「我的」页进来时会把主路由一起 pop 掉
              onTap: () {
                Navigator.of(context).pop();
                onOpenDestination(destination);
              },
            ),
          if (installedPlugins.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: _PluginSlot(),
            )
          else
            for (final plugin in installedPlugins)
              _Item(
                icon: Icons.extension_outlined,
                label: pluginNameOf?.call(plugin.pluginId) ?? plugin.pluginId,
                onTap: () {
                  Navigator.of(context).pop();
                  onOpenPlugin?.call(plugin);
                },
              ),
          const Spacer(),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          for (final destination in footerItems)
            DestinationTile(
              destination: destination,
              onTap: () {
                Navigator.of(context).pop();
                onOpenDestination(destination);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PluginSlot extends StatelessWidget {
  const _PluginSlot();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        '已装插件的入口追加在这里',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
      ),
    );
  }
}
