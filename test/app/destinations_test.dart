// 入口注册表的契约测试。
//
// 侧边栏和「我的」有大量重复入口。这些断言锁住三件事：
//   1. 同一条目只定义一次，两个面都从同一处取
//   2. **发版前不该有"未接入"的灰入口**（2026-10-29 设置页接完后清零）
//   3. 数据备份**不在侧边栏** —— 它属于 设置→数据 那一个角落

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/shell/destinations.dart';

void main() {
  group('AppDestination', () {
    test('每个入口至少出现在一个导航面', () {
      for (final destination in AppDestination.values) {
        expect(destination.surfaces, isNotEmpty, reason: '${destination.id} 没有归属');
      }
    });

    test('侧边栏与「我的」都不为空，插件市场/设置/关于 同时在两边', () {
      final drawer = AppDestination.values
          .where((d) => d.surfaces.contains(DestinationSurface.drawer))
          .toSet();
      final profile = AppDestination.values
          .where((d) => d.surfaces.contains(DestinationSurface.profile))
          .toSet();

      expect(drawer, isNotEmpty);
      expect(profile, isNotEmpty);

      for (final both in <AppDestination>[
        AppDestination.pluginMarket,
        AppDestination.settings,
        AppDestination.about,
      ]) {
        expect(drawer, contains(both));
        expect(profile, contains(both));
      }
    });

    test('数据备份不在入口清单里：它只在 设置→数据', () {
      // 侧边栏塞满了入口之后，"低频操作"和"导航"混在一起。备份是典型低频，
      // 加回侧边栏就等于又把设置页的分组逻辑推倒一次。
      final labels = AppDestination.values.map((d) => d.label).toSet();
      expect(labels, isNot(contains('数据备份')));
    });

    test('没有任何未接入的入口（发版前必须为零）', () {
      // 这条是"别让灰色壳子发出去"的守卫。加新入口时如果先放进 _pending，
      // 它会立刻变红 —— 那不是坏事，是提醒你"这个入口现在还不能点"。
      final pending = AppDestination.values.where((d) => !d.ready).toList();
      expect(
        pending,
        isEmpty,
        reason: '这些入口还是灰的：${pending.map((d) => d.label).join('、')}',
      );
    });
  });

  group('DestinationTile', () {
    // 注：`未接入` 的渲染分支现在走不到（_pending 为空）。等下次加新入口、
    // 先把它放进 _pending 时，这里再补渲染断言 —— 现在为它写测试等于测死代码。
    testWidgets('已接入的入口不带「未接入」标记', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                DestinationTile(
                  destination: AppDestination.pluginMarket,
                  onTap: () {},
                ),
                DestinationTile(
                  destination: AppDestination.settings,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('插件市场'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('未接入'), findsNothing);
    });

    testWidgets('点击会回调，由调用方决定去哪儿', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DestinationTile(
              destination: AppDestination.settings,
              onTap: () => tapped++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('设置'));
      expect(tapped, 1);
    });
  });
}
