import 'package:flutter/material.dart';

import '../../core/home/home_mode.dart';
import '../../core/plugin/plugin_manifest.dart';
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
    this.defaultQuick = false,
    this.order = 100,
  });

  final String? pluginId;
  final String name;
  final String subtitle;

  /// 默认出现在顶栏的快捷切换里。
  ///
  /// true = 插件在 manifest 里声明了 `home`（它是个"模式插件"）。
  /// **false 不等于不能当首页**，只是默认收起来，用户可以在「首页模式」里打开——
  /// 这样既能塞进一批主体模式，又不会把记账、使用说明这类页面一股脑铺到顶栏。
  final bool defaultQuick;

  /// 模式插件的排序（小的在前）。没声明的一律 100，排在声明过的后面。
  final int order;

  bool get isBuiltin => pluginId == null;

  HomeMode get mode =>
      pluginId == null ? const HomeMode.builtin() : HomeMode.plugin(pluginId!);
}

/// 可选模式清单：内置 + 所有已装插件。
///
/// **不区分"这个插件是不是模式插件"** —— 谁都能当首页，插件整页换的只是
/// 内容区，底栏、侧边栏、`+` 都不动，随时能切回内置，没有拦的必要。
/// 真正的区别在默认值：声明了 `home` 的默认出现在快捷切换里，其余默认收起。
///
/// 排序：内置 → 声明了 home 的（按 order）→ 其余（按安装顺序）。
/// 不排的话模式列表会按安装时间漂移，装一个插件位置就变一次。
List<ModeOption> buildModeOptions({
  required List<InstalledPlugin> plugins,
  required String Function(String pluginId) nameOf,
  PluginHomeSpec? Function(String pluginId)? homeOf,
}) {
  final declared = <ModeOption>[];
  final rest = <ModeOption>[];

  for (final plugin in plugins) {
    final home = homeOf?.call(plugin.pluginId);
    final option = ModeOption(
      pluginId: plugin.pluginId,
      // 模式名优先用 home.label：顶栏要塞得下，「周计划」这种插件名太长
      name: home?.label ?? nameOf(plugin.pluginId),
      subtitle: home?.hint ?? '插件整页 · v${plugin.version}',
      defaultQuick: home != null,
      order: home?.order ?? 100,
    );
    (home != null ? declared : rest).add(option);
  }

  declared.sort((a, b) => a.order.compareTo(b.order));

  return <ModeOption>[
    const ModeOption(
      pluginId: null,
      name: '任务模式',
      subtitle: '按天排列的任务 + 日历条',
      defaultQuick: true,
    ),
    ...declared,
    ...rest,
  ];
}

/// 顶栏快捷切换里**实际显示**哪些模式。
///
/// 规则只有三条，多的不要：
/// 1. 内置永远在 —— 插件把首页搞崩时，这是唯一的退路；
/// 2. 当前模式永远在 —— 弹层靠高亮当前项告诉用户"我现在在哪儿"，
///    把它藏起来，点开就成了一堆谁都没选中的选项；
/// 3. 其余看用户的选择，没选过就看默认值（声明了 `home` 的默认开）。
List<ModeOption> quickOptions(
  List<ModeOption> all, {
  required bool Function(ModeOption) visibleOf,
  required HomeMode current,
}) {
  return all
      .where((o) => o.isBuiltin || o.mode == current || visibleOf(o))
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
  PluginHomeSpec? Function(String pluginId)? homeOf,
  VoidCallback? onOpenManager,
}) {
  final all = buildModeOptions(plugins: plugins, nameOf: nameOf, homeOf: homeOf);

  return showDialog<void>(
    context: context,
    // **不用底部弹层**。在这台 Android 17 模拟器上，showModalBottomSheet 画出来的
    // 内容和它的触摸热区整体差约 55dp：点「计划模式」会命中上一行的「任务模式」，
    // 换了 Column、去掉拖拽条、去掉 SafeArea 都一样。返回键能关、widget test 全过，
    // 只有真机点才现形 —— 这种"看着对、点不对"的东西不能留着。
    //
    // 居中对话框在这台机器上坐标是准的，而且只有 4 项以内时，一屏看完比
    // 从底部弹上来更快。
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        clipBehavior: Clip.antiAlias,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final options = quickOptions(
              all,
              visibleOf: (o) =>
                  store.isQuickVisible(o.mode, defaultOn: o.defaultQuick),
              current: store.mode,
            );
            final hiddenCount = all.length - options.length;

            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 2),
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
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (final option in options)
                            ModeTile(
                              option: option,
                              selected: store.mode == option.mode,
                              onTap: () {
                                Navigator.of(ctx).pop();
                                store.setMode(option.mode);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (hiddenCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
                      child: Text(
                        onOpenManager == null
                            ? '另有 $hiddenCount 个模式已收起'
                            : '另有 $hiddenCount 个模式已收起，在「管理」里能放回来',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ),
                ],
              ),
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
