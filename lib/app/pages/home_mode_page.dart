import 'package:flutter/material.dart';

import '../../core/home/home_mode.dart';
import '../../core/plugin/plugin_manifest.dart';
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
///
/// 这一页同时是**快捷项的管理处**：每行右侧的开关决定它要不要出现在
/// 顶栏那个弹层里。插件一多，把用不到的收起来，弹层才不会越拉越长。
class HomeModePage extends StatelessWidget {
  const HomeModePage({
    super.key,
    required this.store,
    required this.plugins,
    required this.nameOf,
    this.homeOf,
  });

  final HomeModeStore store;
  final List<InstalledPlugin> plugins;
  final String Function(String pluginId) nameOf;

  /// 插件声明的 `home`（有 = 模式插件，默认进快捷切换）
  final PluginHomeSpec? Function(String pluginId)? homeOf;

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
              buildModeOptions(plugins: plugins, nameOf: nameOf, homeOf: homeOf);

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
              _sectionHeader(
                context,
                '可选首页',
                hint: plugins.isEmpty ? null : '右侧开关 = 是否进快捷切换',
              ),
              for (final option in options)
                ModeTile(
                  option: option,
                  selected: current == option.mode,
                  onTap: () => store.setMode(option.mode),
                  trailing: _quickSwitch(context, option, current),
                ),
              if (plugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    '还没装插件。去插件市场装一个之后，这里会列出它能当首页的页面。',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
              if (plugins.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Text(
                    '右侧开关控制这个模式进不进顶栏的快捷切换。专做首页的插件默认打开，'
                    '其它插件（例如记账、使用说明）默认关闭 —— 想用就自己打开。\n'
                    '内置模式和当前模式始终进快捷切换：前者是插件出问题时的退路，'
                    '后者让你点开列表就知道自己现在在哪儿。',
                    style: TextStyle(fontSize: 11, height: 1.45, color: scheme.outline),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 每行右侧的开关：这个模式要不要出现在顶栏的快捷切换里。
  ///
  /// 默认值来自插件声明（`home`），所以开关的初始状态不是"全开"：
  /// 模式插件默认开，其它页面插件默认关 —— 用户想要就自己打开。
  /// 内置与当前模式的开关是**禁用的**（且恒为开），原因写在
  /// [HomeModeStore.setQuickVisible]。这里用"禁用"而不是"隐藏"：
  /// 少一行会让插件数量对不上，用户会以为漏了一个。
  Widget _quickSwitch(BuildContext context, ModeOption option, HomeMode current) {
    final locked = option.isBuiltin || option.mode == current;
    final on = locked ||
        store.isQuickVisible(option.mode, defaultOn: option.defaultQuick);
    return Switch(
      key: Key('mode-quick-${option.mode.encode()}'),
      value: on,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onChanged: locked
          ? null
          : (value) => store.setQuickVisible(
                option.mode,
                value,
                defaultOn: option.defaultQuick,
              ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, {String? hint}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (hint != null) ...<Widget>[
            const Spacer(),
            Text(hint, style: TextStyle(fontSize: 10.5, color: scheme.outline)),
          ],
        ],
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
