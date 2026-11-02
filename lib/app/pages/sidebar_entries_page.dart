import 'package:flutter/material.dart';

import '../../core/plugin/plugin_store.dart';
import '../state/plugin_market_store.dart';

/// 侧边栏入口管理：逐个插件决定要不要在侧边栏占一格。
///
/// 和"停用"不是一回事：停用是插件本身不跑（首页、货币位都不给它），
/// 隐藏只是不在侧边栏显示入口 —— 它照样能跑，也能从插件市场打开。
/// 插件一多，侧边栏就会变成一串入口，需要能收起来几个最常用的。
class SidebarEntriesPage extends StatelessWidget {
  const SidebarEntriesPage({super.key, required this.store});

  final PluginMarketStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final plugins = store.installed;
        return Scaffold(
          appBar: AppBar(
            title: const Text('侧边栏入口', style: TextStyle(fontSize: 16)),
          ),
          body: plugins.isEmpty
              ? const Center(
                  child: Text(
                    '还没有安装插件',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                )
              : ListView(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '关闭后该入口不再显示在侧边栏，插件本身仍可正常使用，'
                        '也可以从插件市场打开。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final plugin in plugins)
                      _EntryTile(store: store, plugin: plugin),
                  ],
                ),
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.store, required this.plugin});

  final PluginMarketStore store;
  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final id = plugin.pluginId;
    final name = store.index.findById(id)?.name ?? id;
    final enabled = plugin.enabled;
    final visible = enabled && !store.sidebarHidden.contains(id);

    return SwitchListTile(
      value: visible,
      // 停用的插件本来就不在侧边栏，开关置灰比让它可点更诚实
      onChanged: enabled
          ? (next) => store.setSidebarVisible(id, next)
          : null,
      title: Text(name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        enabled ? 'v${plugin.version}' : '插件已停用',
        style: const TextStyle(fontSize: 11.5),
      ),
    );
  }
}
