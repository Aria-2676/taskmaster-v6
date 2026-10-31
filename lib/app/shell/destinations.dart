import 'package:flutter/material.dart';

/// 入口出现在哪个导航面。同一个入口可以同时出现在多处 ——
/// **内容只写一遍**，由 [AppDestination.surfaces] 决定渲染位置。
enum DestinationSurface { drawer, profile }

/// 全局入口清单。
///
/// 之所以要这一层：侧边栏和「我的」有大量重复入口（数据备份、插件市场、设置、
/// 关于），逐个页面硬编码会出现"两处文案不一致、一处能点一处不能"的问题。
/// 这里定义一次，两个面都从这里取。
///
/// [ready] 为 false 的入口**不是隐藏，而是灰显 + 标注「未接入」**：
/// 用户能看见规划，但不会点了个没反应还以为坏了。
enum AppDestination {
  todayTasks('today', '今日任务', Icons.today_outlined),
  recycleBin('recycle', '任务列表 · 回收站', Icons.inbox_outlined),
  tagManager('tags', '标签管理', Icons.sell_outlined),
  fieldManager('fields', '字段管理', Icons.tune),
  homeMode('home', '首页模式', Icons.dashboard_outlined),
  pluginMarket('market', '插件市场', Icons.extension_outlined),
  settings('settings', '设置', Icons.settings_outlined),
  about('about', '关于', Icons.info_outline);

  const AppDestination(this.id, this.label, this.icon);

  /// 稳定标识，将来可由插件声明"我要往这个位置加东西"
  final String id;
  final String label;
  final IconData icon;

  Set<DestinationSurface> get surfaces => switch (this) {
        todayTasks ||
        recycleBin ||
        tagManager ||
        fieldManager =>
          const <DestinationSurface>{
            DestinationSurface.drawer,
          },
        _ => const <DestinationSurface>{
            DestinationSurface.drawer,
            DestinationSurface.profile,
          },
      };

  /// 还没接入的入口。
  ///
  /// 现在**一个都没有**（设置页接完就清零了）。这个机制留着：以后加新入口时
  /// 先把它放进这个集合，侧边栏会灰显 + 标「未接入」，比"点了没反应"诚实。
  /// 用集合而不是 switch，是因为"全部 ready" 之后 switch 的 default 分支
  /// 会变成不可达代码。
  static const Set<AppDestination> _pending = <AppDestination>{};

  bool get ready => !_pending.contains(this);

  /// 侧边栏里靠底部的两个
  bool get isFooter => this == settings || this == about;
}

/// 统一的入口行。侧边栏与「我的」共用，保证两处外观和状态一致。
class DestinationTile extends StatelessWidget {
  const DestinationTile({
    super.key,
    required this.destination,
    required this.onTap,
    this.selected = false,
    this.showChevron = false,
    this.subtitle,
  });

  final AppDestination destination;
  final VoidCallback onTap;
  final bool selected;

  /// 「我的」页里的入口带右箭头，侧边栏不带
  final bool showChevron;

  /// 入口下面那行小字，例如「已装 2 个 · 启用 1 个」。
  ///
  /// 状态就该长在它对应的入口上：单独拎一行放页面顶部，会跟下面的入口列表
  /// 抢视线，还显得格格不入。侧边栏不传，所以那边一行都没变。
  final String? subtitle;


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = destination.ready;

    final color = !enabled
        ? scheme.onSurface.withValues(alpha: 0.45)
        : selected
            ? scheme.primary
            : scheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: showChevron ? 0 : 16,
          vertical: showChevron ? 12 : 11,
        ),
        child: Row(
          children: <Widget>[
            if (!showChevron) ...<Widget>[
              Icon(destination.icon, size: 18, color: color),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    destination.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 1),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 10.5, color: scheme.outline),
                    ),
                  ],
                ],
              ),
            ),
            if (!enabled)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  '未接入',
                  style: TextStyle(fontSize: 9.5, color: scheme.outline),
                ),
              ),
            if (showChevron) ...<Widget>[
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: scheme.outlineVariant),
            ],
          ],
        ),
      ),
    );
  }
}
