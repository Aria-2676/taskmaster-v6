// 恢复报告页：只测"该说的话有没有说到"，不碰 IO、不点弹层。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/pages/restore_report_page.dart';
import 'package:v5_app/core/backup/backup_service.dart';

void main() {
  RestoreReport reportWith({List<String> dropped = const <String>[], List<String> skipped = const <String>[]}) {
    final report = RestoreReport();
    report.written['任务'] = 3;
    report.written['设置'] = 8;
    report.droppedColumns.addAll(dropped);
    report.skippedPlugins.addAll(skipped);
    return report;
  }

  Future<void> pump(WidgetTester tester, RestoreReport report) => tester.pumpWidget(
        MaterialApp(home: RestoreReportPage(report: report)),
      );

  testWidgets('一切顺利：只报写了多少条，不出现警告段', (tester) async {
    await pump(tester, reportWith());

    expect(find.text('恢复完成'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.textContaining('这些没恢复'), findsNothing);
    expect(find.textContaining('这些字段被忽略'), findsNothing);
  });

  testWidgets('有跳过的插件：标题改口，并给出"先装上再来"的出路', (tester) async {
    await pump(tester, reportWith(skipped: <String>['energy_currency']));

    expect(find.text('恢复完成，但有东西没进来'), findsOneWidget);
    expect(find.textContaining('这些没恢复'), findsOneWidget);
    expect(find.textContaining('energy_currency'), findsOneWidget);
    expect(find.textContaining('先把它装上'), findsOneWidget);
  });

  testWidgets('有被丢弃的字段：逐个列出来，超过 20 个才折叠', (tester) async {
    await pump(tester, reportWith(dropped: <String>['tasks.legacy_col', 'plg_a_x.old']));

    expect(find.textContaining('这些字段被忽略（2）'), findsOneWidget);
    expect(find.textContaining('tasks.legacy_col'), findsOneWidget);
    expect(find.textContaining('plg_a_x.old'), findsOneWidget);
    expect(find.textContaining('等 '), findsNothing, reason: '两个不该折叠');
  });

  testWidgets('丢弃字段很多时：只列 20 个，剩下的用"等 N 个"收尾', (tester) async {
    await pump(tester, reportWith(
      dropped: <String>[for (var i = 0; i < 25; i++) 'tasks.col_$i'],
    ));

    expect(find.textContaining('这些字段被忽略（25）'), findsOneWidget);
    expect(find.textContaining('tasks.col_0'), findsOneWidget);
    expect(find.textContaining('tasks.col_24'), findsNothing);
    expect(find.text('等 25 个'), findsOneWidget);
  });

  testWidgets('一条都没写进去时：明说，而不是显示空白', (tester) async {
    final report = RestoreReport();
    await pump(tester, report);

    expect(find.text('没有写入任何数据'), findsOneWidget);
  });
}
