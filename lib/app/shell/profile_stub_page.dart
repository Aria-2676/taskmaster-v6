import 'package:flutter/material.dart';

import 'destinations.dart';

/// 「我的」页：**只放"我是谁"和入口**。
///
/// 以前这里还塞了日历条形态、删除确认、回收站保留时长这些开关，结果是同一页
/// 上半截是身份、下半截是配置面板，加几个功能就挤成一锅。开关全部搬到
/// 设置页（见 `pages/settings_page.dart`），这里只留：当前货币、插件概况、
/// 以及通往各处的入口。
class ProfileStubPage extends StatelessWidget {
  const ProfileStubPage({
    super.key,
    required this.currencyLabel,
    required this.pluginSummary,
    required this.onOpenDestination,
  });

  /// 顶部那行货币文案（由主壳算好，这里不碰状态）
  final String currencyLabel;

  /// 例如「已装 2 个插件 · 启用 1 个」。零插件时显示提示去装一个
  final String pluginSummary;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.bolt, size: 18, color: scheme.outline),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      currencyLabel,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Icon(Icons.extension_outlined, size: 18, color: scheme.outline),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pluginSummary,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
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
