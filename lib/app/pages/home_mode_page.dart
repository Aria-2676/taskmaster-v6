import 'package:flutter/material.dart';

import '../../core/plugin/plugin_store.dart';
import '../state/home_mode_store.dart';
import '../widgets/mode_switcher.dart';

/// 首页模式：内置任务模式，或者某个已装插件提供的整页。
///
/// **外壳不换**：底栏、侧边栏、添加按钮永远由主包画，插件只填内容区。
/// 页面上要把这句话说清楚 —— 否则用户会以为"换首页"等于换掉整个应用。
///
/// 可选清单和顶栏的快捷切换器**共用 [buildModeOptions]**：
/// 两处各写一份的结果是"这里能选、那里选不了"，而且迟早出现名字对不上。
class HomeModePage extends StatelessWidget {
  const HomeModePage({
    super.key,
    required this.store,
    required this.plugins,
    required this.nameOf,
  });

  final HomeModeStore store;
  final List<InstalledPlugin> plugins;
  final String Function(String pluginId) nameOf;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('首页模式', style: TextStyle(fontSize: 16)),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final current = store.mode;
          final options =
              buildModeOptions(plugins: plugins, nameOf: nameOf);

          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '换首页只换中间的内容区，底栏和侧边栏仍然是主包的。'
                  '插件加载失败会自动切回内置首页。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: scheme.outline),
                ),
              ),
              if (store.autoDowngraded)
                _warning(
                  context,
                  '上次启动没能正常显示插件首页，已自动切回内置。'
                  '连续失败 ${store.failures} 次。',
                )
              else if (!current.isBuiltin && store.failures > 0)
                _warning(context, '这个首页上次加载失败 ${store.failures} 次，再失败一次就会自动切回内置。'),
              for (final option in options)
                ModeTile(
                  option: option,
                  selected: current == option.mode,
                  onTap: () => store.setMode(option.mode),
                ),
              if (plugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    '还没装插件。去插件市场装一个之后，这里会列出它能当首页的页面。',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _warning(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 15, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.4, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
