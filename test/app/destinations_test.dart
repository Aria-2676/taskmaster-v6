// 入口注册表的契约测试。
//
// 侧边栏和「我的」有大量重复入口。这些断言锁住两件事：
//   1. 同一条目只定义一次，两个面都从同一处取
//   2. 没做完的入口必须**看得出来**（灰显 + 「未接入」），而不是点了没反应

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

    test('侧边栏与「我的」都不为空，且数据备份/插件市场/设置/关于 同时在两边', () {
      final drawer = AppDestination.values
          .where((d) => d.surfaces.contains(DestinationSurface.drawer))
          .toSet();
      final profile = AppDestination.values
          .where((d) => d.surfaces.contains(DestinationSurface.profile))
          .toSet();

      expect(drawer, isNotEmpty);
      expect(profile, isNotEmpty);

      for (final both in <AppDestination>[
        AppDestination.backup,
        AppDestination.pluginMarket,
        AppDestination.settings,
        AppDestination.about,
      ]) {
        expect(drawer, contains(both));
        expect(profile, contains(both));
      }
    });

    test('已接入的入口就是这几个', () {
      final ready = AppDestination.values.where((d) => d.ready).toSet();
      expect(ready, <AppDestination>{
        AppDestination.todayTasks,
        AppDestination.recycleBin,
        AppDestination.tagManager,
        AppDestination.fieldManager,
        AppDestination.homeMode,
        AppDestination.pluginMarket,
        // 关于 = 版本信息 + 手动检查更新。少了它，"跳过了某个版本"就再没有
        // 反悔的入口 —— 自动提示被跳过之后，用户只能等新版本。
        AppDestination.about,
      });
    });
  });

  group('DestinationTile', () {
    testWidgets('未接入的入口带「未接入」标记，已接入的不带', (tester) async {
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
      expect(find.text('未接入'), findsOneWidget, reason: '只有"设置"该带标记');
    });

    testWidgets('点击仍然会回调，由调用方决定怎么提示', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DestinationTile(
              destination: AppDestination.backup,
              onTap: () => tapped++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('数据备份'));
      expect(tapped, 1);
    });
  });
}
