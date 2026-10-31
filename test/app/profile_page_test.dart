// 「我的」页顶部：货币卡片什么时候画、画成什么样。
//
// 两件事必须锁住：
//   1. 没有货币插件时**整块不出现** —— 这一页不该堆"你没有这个"的提示
//   2. 有货币时能把"谁给的"和"余额"分开显示，金额带千分位
//
// 只是排版，不涉及状态，所以直接 pump 这个 widget，不经过主壳。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/shell/destinations.dart';
import 'package:v5_app/app/shell/profile_stub_page.dart';

Future<void> _pump(
  WidgetTester tester, {
  required CurrencySummary? currency,
  String summary = '已装 2 个 · 启用 1 个',
  ValueChanged<AppDestination>? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProfileStubPage(
          currency: currency,
          pluginSummary: summary,
          onOpenDestination: onOpen ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('金额格式', () {
    test('三位以内不加分隔符', () {
      expect(formatAmount(0), '0');
      expect(formatAmount(999), '999');
    });

    test('四位以上按千分位分组', () {
      expect(formatAmount(1000), '1,000');
      expect(formatAmount(12345), '12,345');
      expect(formatAmount(1234567), '1,234,567');
    });

    test('负数把符号留在最前面，别出现 -,123', () {
      expect(formatAmount(-1234), '-1,234');
    });
  });

  group('货币卡片', () {
    testWidgets('没有货币插件：整块不画，也不留"未安装"字样', (tester) async {
      await _pump(tester, currency: null);

      expect(find.byKey(const Key('profile-currency-balance')), findsNothing);
      expect(find.textContaining('未安装'), findsNothing);
      expect(find.textContaining('当前货币'), findsNothing);
      // 顶部第一块就是「入口」，没有别的东西插在前面
      expect(find.text('入口'), findsOneWidget);
    });

    testWidgets('有货币：插件名 + 千分位余额分两行显示', (tester) async {
      await _pump(
        tester,
        currency: const CurrencySummary(providerName: '记账', balance: 12800),
      );

      expect(find.text('记账'), findsOneWidget);
      expect(find.text('12,800'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('插件名过长不溢出', (tester) async {
      await _pump(
        tester,
        currency: const CurrencySummary(
          providerName: '一个名字特别特别长的记账插件用来测试截断',
          balance: 1,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('插件数量', () {
    testWidgets('挂在「插件市场」入口下面，不单独占一行', (tester) async {
      await _pump(tester, currency: null, summary: '已装 2 个 · 启用 1 个');

      final marketTile = find.ancestor(
        of: find.text('插件市场'),
        matching: find.byType(DestinationTile),
      );
      expect(marketTile, findsOneWidget);
      expect(
        find.descendant(
          of: marketTile,
          matching: find.text('已装 2 个 · 启用 1 个'),
        ),
        findsOneWidget,
        reason: '状态要长在它对应的入口上，不要单独占页面顶部',
      );
    });

    testWidgets('点这行去插件市场', (tester) async {
      AppDestination? opened;
      await _pump(
        tester,
        currency: null,
        summary: '还没装插件',
        onOpen: (d) => opened = d,
      );

      await tester.tap(find.text('还没装插件'));
      await tester.pumpAndSettle();

      expect(opened, AppDestination.pluginMarket);
    });
  });
}
