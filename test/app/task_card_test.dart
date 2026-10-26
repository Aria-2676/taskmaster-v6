// 任务卡片的展示契约。
//
// 专门盯"标签被悄悄截断"这类问题：界面少显示一个字段，不会报错、不会崩，
// 用户只会以为"我打的标签没保存"，然后反复重打。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/widgets/task_card.dart';

Task task({
  String title = '测试任务',
  List<Tag> tags = const <Tag>[],
  int? minutes,
}) =>
    Task(
      id: 1,
      title: title,
      dueDate: DateTime(2026, 10, 26),
      priority: 'white',
      isDone: false,
      tags: tags,
      estimatedMinutes: minutes,
    );

Tag tag(int id, String name) => Tag(id: id, name: name);

void main() {
  Future<void> pump(WidgetTester tester, Task t) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: <Widget>[TaskCard(task: t, onToggle: () {})]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三个标签全部显示（不截断）', (tester) async {
    await pump(tester, task(tags: <Tag>[tag(1, '工作'), tag(2, '学习'), tag(3, '生活')]));

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('学习'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget, reason: '第三个标签不能凭空消失');
    expect(tester.takeException(), isNull, reason: '换行不能触发溢出');
  });

  testWidgets('标签多到需要换行时也不溢出', (tester) async {
    await pump(
      tester,
      task(tags: <Tag>[
        for (int i = 1; i <= 7; i++) tag(i, '标签$i'),
      ]),
    );

    for (int i = 1; i <= 7; i++) {
      expect(find.text('标签$i'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('时长与标签在同一行，没有标签时也不留空行', (tester) async {
    await pump(tester, task(minutes: 30));
    expect(find.text('30 分钟'), findsOneWidget);

    await pump(tester, task(tags: <Tag>[tag(1, '工作')], minutes: 30));
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('30 分钟'), findsOneWidget);
  });

  testWidgets('既没有标签也没有时长：不渲染任何 chip 行', (tester) async {
    await pump(tester, task());
    expect(find.text('测试任务'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsNothing);
  });
}
