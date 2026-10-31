import 'package:flutter/material.dart';

import 'destinations.dart';

/// 「我的」页顶部的货币摘要。`null` = 没有货币插件，整块不画。
///
/// 之所以拆成对象而不是直接传一句拼好的字符串：卡片要分层排版
/// （插件名小字、余额大字），拼成一句就只能平铺一行，怎么调都丑。
class CurrencySummary {
  const CurrencySummary({required this.providerName, required this.balance});

  /// 提供货币的插件名，例如「记账」
  final String providerName;

  final int balance;
}

/// 「我的」页：**只放"我是谁"和入口**。
///
/// 以前这里还塞了日历条形态、删除确认、回收站保留时长这些开关，结果是同一页
/// 上半截是身份、下半截是配置面板，加几个功能就挤成一锅。开关全部搬到
/// 设置页（见 `pages/settings_page.dart`），这里只留：货币卡片、插件概况、
/// 以及通往各处的入口。
///
/// 货币卡片**没装货币插件时整个不画**。以前那行写的是"当前货币：未安装"，
/// 一进「我的」就顶着一句"你没有这个"——没有的功能不该占位置，
/// 否则每加一个可选能力，这一页就多一行"未安装"。
class ProfileStubPage extends StatelessWidget {
  const ProfileStubPage({
    super.key,
    required this.currency,
    required this.pluginSummary,
    required this.onOpenDestination,
  });

  /// 当前货币。null = 不显示这一块（由主壳算好，这里不碰状态）
  final CurrencySummary? currency;

  /// 例如「已装 2 个插件 · 启用 1 个」。零插件时提示去装一个
  final String pluginSummary;

  final ValueChanged<AppDestination> onOpenDestination;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = currency;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        if (summary != null) ...<Widget>[
          _CurrencyCard(currency: summary),
          const SizedBox(height: 10),
        ],
        _PluginRow(
          summary: pluginSummary,
          onTap: () => onOpenDestination(AppDestination.pluginMarket),
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

/// 货币卡片：谁给的 + 多少。
///
/// 配色跟顶栏那个琥珀色数字同源（见 `main_shell.dart` 的 `_CurrencyBadge`），
/// 让用户一眼认出"我在这里看到的数字，和顶栏那个是同一个"。
class _CurrencyCard extends StatelessWidget {
  const _CurrencyCard({required this.currency});

  final CurrencySummary currency;

  /// 浅色主题下用深一点的琥珀保证对比度，深色主题下提亮 ——
  /// 同一个色值在两种背景上没法都清楚。
  Color _accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFFCA28)
          : const Color(0xFFF57F17);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _accent(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.bolt_rounded, size: 21, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  currency.providerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 1),
                Text(
                  formatAmount(currency.balance),
                  key: const Key('profile-currency-balance'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 23,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                    // 等宽数字：余额刷新时不会左右抖
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 插件概况：一行状态 + 右箭头，点进去就是插件市场。
///
/// 做成可点是因为文案本身就在邀请用户（"去插件市场看看"），
/// 一行写着"去看看"却点不动，比不写更让人别扭。
class _PluginRow extends StatelessWidget {
  const _PluginRow({required this.summary, required this.onTap});

  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(Icons.extension_outlined, size: 15, color: scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: scheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// 千分位。余额是纯整数、可能上万，不加分隔符要一个个数零。
///
/// 没用 `intl`：主包现在没这个依赖，为了一处显示拉一个包不值得。
String formatAmount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return value < 0 ? '-$buffer' : buffer.toString();
}
