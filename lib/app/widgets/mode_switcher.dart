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

/// 顶栏快捷切换里**实际显示**哪些模式。
///
/// 规则只有三条，多的不要：
/// 1. 内置永远在 —— 插件把首页搞崩时，这是唯一的退路；
/// 2. 当前模式永远在 —— 弹层靠高亮当前项告诉用户"我现在在哪儿"，
///    把它藏起来，点开就成了一堆谁都没选中的选项；
/// 3. 其余听用户的 —— [hidden] 里被收起来的不出现。
///
/// 第 2 条在 [HomeModeStore.setQuickHidden] 里已经拦过一道，这里再兜一次：
/// 历史数据里可能留着"当前模式被收起"的记录，那时不该让用户对着一个
/// 没有选中项的列表发懵。
List<ModeOption> quickOptions(
  List<ModeOption> all, {
  required Set<String> hidden,
  required HomeMode current,
}) {
  return all
      .where((o) =>
          o.isBuiltin || o.mode == current || !hidden.contains(o.mode.encode()))
      .toList(growable: false);
}

/// 顶栏用的快捷切换器：底部弹层，点一下就是切。
///
/// 和设置里的「首页模式」页不是重复功能：那页负责解释、失败告警和
/// **管理快捷项**，这个只负责"随手换一个"。真正写状态的都走 [HomeModeStore]。
///
/// 列表**只放用户没收起的那几个**。插件一多，把十来个模式全铺进这里，
/// 常用的那几个会被挤到要滚动才看得见 —— 快捷入口一旦要滚，就不快捷了。
Future<void> showModeSwitcher(
  BuildContext context, {
  required HomeModeStore store,
  required List<InstalledPlugin> plugins,
  required String Function(String pluginId) nameOf,
  VoidCallback? onOpenManager,
}) {
  final all = buildModeOptions(plugins: plugins, nameOf: nameOf);

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
            final options = quickOptions(
              all,
              hidden: store.hiddenQuickKeys,
              current: store.mode,
            );
            final hiddenCount = all.length - options.length;

            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 10),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '快捷切换',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (onOpenManager != null)
                        TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            onOpenManager();
                          },
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 30),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('管理', style: TextStyle(fontSize: 12.5)),
                        ),
                    ],
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
                if (hiddenCount > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      onOpenManager == null
                          ? '另有 $hiddenCount 个模式已收起'
                          : '另有 $hiddenCount 个模式已收起，在「管理」里能放回来',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  ),
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
    this.trailing,
  });

  final ModeOption option;
  final bool selected;
  final VoidCallback onTap;

  /// 右侧控件。为 null 时沿用"选中就打勾"的默认表现 ——
  /// 设置页要在同一个位置放开关，两处共用这一个 tile。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: onTap,
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.06),
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
      trailing: trailing ??
          (selected ? Icon(Icons.check, size: 18, color: scheme.primary) : null),
    );
  }
}
