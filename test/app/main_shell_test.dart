// v6 主包外壳的冒烟测试。
//
// 目的不是逐像素校验，而是挡住四类最伤的问题：
//   1. 布局溢出（Overflow 会在测试里变成异常）
//   2. 导航结构缺件（底栏三项、抽屉、日历条）
//   3. 交互链路断掉（勾选、添加、删除）
//   4. 插槽失效（有插件数据却渲染不出来，或没插件时多出东西）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/demo_seed.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/app/v6_preview_app.dart';
import 'package:v5_app/app/widgets/calendar_strip.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_slot.dart';

/// 模拟"已经加载过一次（ready=true）、正在重新加载（loading=true）、
/// 但列表暂时为空"的状态。
class _StaleLoadingStore extends TaskStore {
  _StaleLoadingStore(super.repo, super.settings);

  @override
  bool get loading => true;

  @override
  List<Task> get tasks => const <Task>[];

  @override
  bool get ready => true;

  @override
  Future<void> load([DateTime? day]) async {}
}

/// 假插件：只负责"按插槽返回数据"，验证主包确实消费了插槽。
class _FakeSlotProvider implements SlotProvider {
  _FakeSlotProvider(this.values);

  final Map<SlotId, SlotValue Function()> values;

  @override
  String get pluginId => 'test.fake';

  @override
  Set<SlotId> get slots => values.keys.toSet();

  @override
  SlotValue? provide(SlotId slot, Map<String, Object?> context) => values[slot]?.call();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // 用 NoIsolate 版本：默认实现把 SQL 发到子 isolate，`pumpAndSettle` 只等帧调度、
    // 不等真实 IO，于是"点了删除但断言时还没落库"。同 isolate 下操作在微任务里完成，
    // pump 就能推进，测试才是确定性的。
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;
  late TaskStore store;

  setUp(() async {
    SlotRegistry.instance.clear();
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);

    repo = TaskRepository(db);
    await DemoSeed.runIfEmpty(repo);
    store = TaskStore(repo, SettingsRepository(db));
    await store.load();
  });

  tearDown(() => SlotRegistry.instance.clear());

  /// 用手机逻辑尺寸（360×780）跑，而不是默认的 800×600 ——
  /// 否则列表放不下 6 张卡片，`find.text` 会因懒加载找不到目标。
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 触发写库操作后用它替代裸 `pumpAndSettle`：
  /// 数据库调用即使不走 isolate，也要经过几轮微任务才会 notifyListeners。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  /// 开关从「我的」搬到设置页了：先切到「我的」，再点进「设置」。
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(V6PreviewApp(store: store));
    await settle(tester);
  }

  String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  testWidgets('第一屏能渲染：日历条 + 底栏三项', (tester) async {
    await pumpApp(tester);

    expect(find.byType(CalendarStrip), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '渲染期不应有异常/溢出');
  });

  testWidgets('任务从数据库读出来并显示', (tester) async {
    await pumpApp(tester);

    // DemoSeed 今天写了 4 条任务
    expect(find.text('写完 v6 主包的第一屏'), findsOneWidget);
    expect(find.text('散步 20 分钟'), findsOneWidget);
  });

  testWidgets('勾选任务会写库并变成已完成', (tester) async {
    await pumpApp(tester);

    final before = tester.widgetList(find.byIcon(Icons.check_circle)).length;
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await settle(tester);
    final after = tester.widgetList(find.byIcon(Icons.check_circle)).length;

    expect(after, before + 1);

    // 再取一次库，确认是真落盘而不是只改了内存（seed 里本来就有 1 条已完成）
    expect(store.tasks.where((t) => t.isDone).length, 2, reason: '库里应有 2 条已完成');
  });

  testWidgets('左滑删除：确认框点「删除」才真的删', (tester) async {
    await pumpApp(tester);

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(find.text('删除任务'), findsOneWidget, reason: '默认会先问一句');
    await tester.tap(find.text('删除'));
    await settle(tester);

    expect(find.text('读 30 页《设计心理学》'), findsNothing);
    expect(find.textContaining('已删除'), findsOneWidget);
  });

  testWidgets('删除确认框：点「取消」任务原样保留', (tester) async {
    await pumpApp(tester);

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('读 30 页《设计心理学》'), findsOneWidget);
    expect(find.text('删除任务'), findsNothing);
  });

  testWidgets('关闭删除确认后左滑，必须真的从库里删掉', (tester) async {
    // 这是真实出现过的问题：确认框关掉后，confirmDismiss 直接放行，
    // 而登记"待删除"只发生在弹窗那条分支上 → onDismissed 认领不到，
    // 于是一条都没删：卡片从界面消失、库里还在，切个日期它就回来了。
    await pumpApp(tester);
    await store.setConfirmBeforeDelete(false);
    await settle(tester);

    const title = '读 30 页《设计心理学》';
    expect(store.tasks.any((t) => t.title == title), isTrue);

    await tester.drag(find.text(title), const Offset(-400, 0));
    await settle(tester);

    expect(find.text(title), findsNothing, reason: '界面上应该没了');

    final rows = await repo.tasksOn(DateTime.now());
    expect(rows.any((t) => t.title == title), isFalse,
        reason: '库里也必须没了，否则切回日期它会复活');

    // 回收站默认关 → 直接物理删除，不留垃圾
    final recycled = await db.query('recycled_tasks');
    expect(recycled, isEmpty, reason: '默认应当是彻底删除，回收站里不该有东西');
  });

  testWidgets('打开回收站开关后，左滑进回收站而不是直接删', (tester) async {
    await pumpApp(tester);
    await store.setConfirmBeforeDelete(false);
    await store.setRecycleBinEnabled(true);
    await settle(tester);

    const title = '读 30 页《设计心理学》';
    await tester.drag(find.text(title), const Offset(-400, 0));
    await settle(tester);

    expect(find.text(title), findsNothing);
    expect(find.textContaining('已移入回收站'), findsOneWidget, reason: '提示要说明去了哪儿');

    final recycled = await db.query('recycled_tasks');
    expect(recycled.any((r) => r['title'] == title), isTrue);

    // 切走再切回来：任务不该复活（它在回收站，不在当天列表里）
    await store.load(DateTime.now().add(const Duration(days: 3)));
    await settle(tester);
    await store.load(DateTime.now());
    await settle(tester);
    expect(find.text(title), findsNothing);
  });

  testWidgets('改短保留时长会先问一句；取消则设置和条目都不变', (tester) async {
    await pumpApp(tester);
    await store.setRecycleBinEnabled(true);
    final id = await repo.insert(title: '三天前删的', day: DateTime.now());
    await repo.moveToRecycle(id);
    await db.update(
      'recycled_tasks',
      <String, Object?>{
        'deleted_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 3))
            .toIso8601String(),
      },
      where: 'title = ?',
      whereArgs: <Object?>['三天前删的'],
    );
    await settle(tester);

    await openSettings(tester);
    await tester.tap(find.text('1 天'));
    await settle(tester);

    expect(find.text('缩短保留时长'), findsOneWidget);
    expect(find.textContaining('1 条已经超过 1 天'), findsOneWidget,
        reason: '确认框要说清楚会删几条');

    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(store.retentionDays, 7, reason: '取消后设置不能变');
    expect(await repo.recycledCount(), 1, reason: '取消后一条都不能少');
  });

  testWidgets('改短保留时长确认后：清掉条目并给出提示', (tester) async {
    await pumpApp(tester);
    await store.setRecycleBinEnabled(true);
    final id = await repo.insert(title: '三天前删的', day: DateTime.now());
    await repo.moveToRecycle(id);
    await db.update(
      'recycled_tasks',
      <String, Object?>{
        'deleted_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 3))
            .toIso8601String(),
      },
      where: 'title = ?',
      whereArgs: <Object?>['三天前删的'],
    );
    await settle(tester);

    await openSettings(tester);
    await tester.tap(find.text('1 天'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await settle(tester);

    expect(store.retentionDays, 1);
    expect(await repo.recycledCount(), 0);
    expect(find.textContaining('已按新的保留时长清理 1 条'), findsOneWidget);
  });

  testWidgets('设置页拨开关后界面要立刻更新（不监听 store 就纹丝不动）', (tester) async {
    await pumpApp(tester);
    await store.setRecycleBinEnabled(false);
    await settle(tester);
    await openSettings(tester);

    expect(find.text('保留时长'), findsNothing, reason: '回收站关着时不该出现保留时长');

    await tester.tap(find.widgetWithText(SwitchListTile, '删除后先进回收站'));
    await settle(tester);

    expect(store.recycleBinEnabled, isTrue);
    // 这条是在真机上踩出来的：设置页当初是 StatelessWidget 且没监听 store，
    // 拨了开关数据变了、界面不动，用户以为没点上。
    expect(find.text('保留时长'), findsOneWidget, reason: '拨开后要立刻出现保留时长');
  });

  testWidgets('改短但没有过期条目：不弹框，直接生效', (tester) async {
    await pumpApp(tester);
    await store.setRecycleBinEnabled(true);
    await settle(tester);

    await openSettings(tester);
    await tester.tap(find.text('3 天'));
    await settle(tester);

    expect(find.text('缩短保留时长'), findsNothing, reason: '没有东西要删就别打扰');
    expect(store.retentionDays, 3);
  });

  test('把保留时长改短，过期条目会被立刻清掉', () async {
    final id = await repo.insert(title: '三天前删的', day: DateTime.now());
    await repo.moveToRecycle(id);
    await db.update(
      'recycled_tasks',
      <String, Object?>{
        'deleted_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 3))
            .toIso8601String(),
      },
      where: 'title = ?',
      whereArgs: <Object?>['三天前删的'],
    );
    expect(await repo.recycledCount(), 1);

    // 默认 7 天 → 改成 1 天，这条已经过期
    final purged = await store.setRetentionDays(1);

    expect(purged, 1, reason: '要返回清掉的条数，界面靠它给提示');
    expect(await repo.recycledCount(), 0);
    expect(store.retentionDays, 1);
  });

  test('回收站开关与保留时长会写进 settings 表', () async {
    expect(store.recycleBinEnabled, isFalse, reason: '默认必须关');
    expect(store.retentionDays, 7);

    await store.setRecycleBinEnabled(true);
    await store.setRetentionDays(3);

    final fresh = TaskStore(repo, SettingsRepository(db));
    await fresh.load();
    expect(fresh.recycleBinEnabled, isTrue);
    expect(fresh.retentionDays, 3);
  });

  testWidgets('删掉之后再切日期往返，任务不会复活', (tester) async {
    await pumpApp(tester);
    await store.setConfirmBeforeDelete(false);
    await settle(tester);

    const title = '读 30 页《设计心理学》';
    await tester.drag(find.text(title), const Offset(-400, 0));
    await settle(tester);

    // 切走再切回：走的是同一套 load()
    await store.load(DateTime.now().add(const Duration(days: 3)));
    await settle(tester);
    await store.load(DateTime.now());
    await settle(tester);

    expect(find.text(title), findsNothing, reason: '往返之后不该复活');
  });

  testWidgets('勾「以后不再提醒」时，弹窗里就说明怎么开回来', (tester) async {
    await pumpApp(tester);

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // 没勾之前不该提前占位
    expect(find.textContaining('可在「我的'), findsNothing);

    await tester.tap(find.text('以后不再提醒'));
    await tester.pumpAndSettle();

    expect(find.textContaining('可在「我的 › 删除前确认」'), findsOneWidget,
        reason: '勾上的当下就要把后果讲清楚，而不是等删除后再补一条底部横幅');

    await tester.tap(find.text('删除'));
    await settle(tester);

    expect(find.text('读 30 页《设计心理学》'), findsNothing);
    expect(find.textContaining('删除确认已关闭'), findsOneWidget);

    // 再滑一条：不该再弹窗
    await tester.drag(find.text('写完 v6 主包的第一屏'), const Offset(-400, 0));
    await settle(tester);
    expect(find.text('删除任务'), findsNothing, reason: '已经关掉提醒了');
    expect(find.text('写完 v6 主包的第一屏'), findsNothing);
  });

  testWidgets('删除后的短提示会自己消失', (tester) async {
    await pumpApp(tester);

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('以后不再提醒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle(tester);

    expect(find.textContaining('已删除'), findsWidgets);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.textContaining('已删除'), findsNothing, reason: '短提示不能赖着不走');
  });

  testWidgets('勾了不再提醒时，设置要等任务真的删掉之后才改', (tester) async {
    // 旧实现是在 confirmDismiss 里就写设置，那会在 Dismissible 等结果时
    // 触发一次 rebuild，真机上会把卡片卡在"完全滑出"的状态（onDismissed 不触发）。
    // 这条断言锁住顺序：先删任务（4 条 → 3 条），再改设置。
    await pumpApp(tester);
    expect(store.tasks.length, 4);

    final events = <String>[];
    void record() =>
        events.add('${store.tasks.length}|${store.confirmBeforeDelete}');
    store.addListener(record);
    addTearDown(() => store.removeListener(record));

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('以后不再提醒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle(tester);

    final firstDisabled =
        events.firstWhere((e) => e.endsWith('|false'), orElse: () => '');
    expect(firstDisabled, isNotEmpty, reason: '最终应该把设置改成 false');
    expect(firstDisabled, startsWith('3|'),
        reason: '改设置时必须已经是 3 条任务（删除动作已完成），实际事件：$events');
  });

  test('「不再提醒」写进 settings 表，重启后仍然生效', () async {
    expect(store.confirmBeforeDelete, isTrue, reason: '新库默认要确认');

    await store.setConfirmBeforeDelete(false);

    // 模拟重启：新建一个 store 读同一个库
    final fresh = TaskStore(repo, SettingsRepository(db));
    await fresh.load();
    expect(fresh.confirmBeforeDelete, isFalse);

    await fresh.setConfirmBeforeDelete(true);
    final again = TaskStore(repo, SettingsRepository(db));
    await again.load();
    expect(again.confirmBeforeDelete, isTrue);
  });

  testWidgets('「我的」里能把删除确认重新打开', (tester) async {
    await pumpApp(tester);

    await store.setConfirmBeforeDelete(false);
    await settle(tester);

    await openSettings(tester);

    expect(find.text('删除前确认'), findsOneWidget);

    final confirmSwitch = find.widgetWithText(SwitchListTile, '删除前确认');
    expect(tester.widget<SwitchListTile>(confirmSwitch).value, isFalse);

    await tester.tap(confirmSwitch);
    await settle(tester);

    expect(store.confirmBeforeDelete, isTrue);
  });

  testWidgets('切日期不会重建日历条（否则滚动位置会跳回）', (tester) async {
    await pumpApp(tester);

    final strip = find.byType(CalendarStrip);
    final stateBefore = tester.state(strip);
    final scrollable = find.descendant(of: strip, matching: find.byType(Scrollable));
    final pixelsBefore =
        tester.state<ScrollableState>(scrollable).position.pixels;

    final today = DateTime.now();
    await tester.tap(
      find.descendant(of: strip, matching: find.text('${today.day}')).first,
    );
    await settle(tester);

    expect(tester.state(find.byType(CalendarStrip)), same(stateBefore),
        reason: '切日期不该重建日历条');
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      closeTo(pixelsBefore, 0.5),
      reason: '日历条位置不该因为切日期而移动',
    );
  });

  testWidgets('已加载过之后，切到空日期不会换成全屏 loading', (tester) async {
    // 直接构造"曾经加载过、现在正在 loading、列表暂时为空"这个状态。
    // 用真实时序很难稳定地卡在两个 await 之间，而这个状态正是会让日历条
    // 被销毁重建（于是滚回选中周）的那个状态。
    final stale = _StaleLoadingStore(repo, SettingsRepository(db));

    usePhoneViewport(tester);
    await tester.pumpWidget(V6PreviewApp(store: stale));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '切日期时不该把整棵树换成加载圈');
    expect(find.byType(CalendarStrip), findsOneWidget,
        reason: '日历条不该被销毁重建');
  });

  testWidgets('侧边栏能打开，并挂出插件入口位', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('插件市场'), findsWidgets);
    expect(find.text('已装插件的入口追加在这里'), findsOneWidget);
  });

  testWidgets('底栏中间按钮进新建页，填标题就能存', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);

    expect(find.text('新建任务'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.text('添加'));
    await settle(tester);

    expect(find.text('买牛奶'), findsOneWidget);
    expect(find.textContaining('已添加'), findsOneWidget);
  });

  testWidgets('日期选择器是中文的（预览壳配了本地化）', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('读 30 页《设计心理学》'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.event_outlined));
    await tester.pumpAndSettle();

    // 没配 GlobalMaterialLocalizations 时这里是 OK / CANCEL
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('点任务正文打开编辑页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('读 30 页《设计心理学》'));
    await settle(tester);

    expect(find.text('编辑任务'), findsOneWidget);
    expect(find.widgetWithText(TextField, '读 30 页《设计心理学》'), findsOneWidget);
  });

  testWidgets('回收站关着时，删除弹窗说的是「彻底删除」', (tester) async {
    await pumpApp(tester);

    await tester.drag(find.text('读 30 页《设计心理学》'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(find.textContaining('将被彻底删除'), findsOneWidget,
        reason: '默认直接删，不能还写"移入回收站"');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('新建任务时能给任务选标签', (tester) async {
    await pumpApp(tester);
    expect(store.tags.map((t) => t.name), contains('工作'));

    await tester.tap(find.byIcon(Icons.add));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, '带标签的新任务');
    // 新建页里的标签是 Material 的 FilterChip（首页那排是自绘的 _FilterChip），不会撞
    await tester.tap(find.widgetWithText(FilterChip, '工作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await settle(tester);

    final added = store.tasks.firstWhere((t) => t.title == '带标签的新任务');
    expect(added.tags.map((t) => t.name), <String>['工作']);
  });

  testWidgets('切到「固定一周」后，日历条不再是横向列表', (tester) async {
    await pumpApp(tester);

    int horizontalLists() => tester
        .widgetList(find.byWidgetPredicate(
            (w) => w is ListView && w.scrollDirection == Axis.horizontal))
        .length;

    final before = horizontalLists();

    await openSettings(tester);
    await tester.tap(find.text('固定一周'));
    await tester.pumpAndSettle();
    // 不用 tester.pageBack()：它按 tooltip 'Back' 找按钮，中文包里是「返回」，
    // 找不到就报 "One back button expected on screen"。直接点 BackButton 类型。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    expect(horizontalLists(), lessThan(before), reason: '周视图不该再有横向日历列表');
  });

  testWidgets('轻扫一下正好前进一周（不会弹回原地）', (tester) async {
    await pumpApp(tester);

    final strip = find.byType(CalendarStrip);
    final scrollable = find.descendant(of: strip, matching: find.byType(Scrollable));
    final weekWidth = tester.getSize(strip).width; // 一屏正好一周
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    // 只拖一小段（不足半周），但有速度，仍应走满一周
    await tester.fling(scrollable, const Offset(-60, 0), 1200);
    await tester.pumpAndSettle();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect((after - before - weekWidth).abs(), lessThan(2.0),
        reason: '小位移应正好走一周，实际 $before -> $after，周宽 $weekWidth');
  });

  testWidgets('几乎没动时不翻页（防误触）', (tester) async {
    await pumpApp(tester);

    final scrollable =
        find.descendant(of: find.byType(CalendarStrip), matching: find.byType(Scrollable));
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    // 慢慢挪 4px 再松手：没有速度，应弹回整周原位
    await tester.timedDrag(
      scrollable,
      const Offset(-4, 0),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();

    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(before, 0.5));
  });

  testWidgets('大位移仍按整周吸附', (tester) async {
    await pumpApp(tester);

    final strip = find.byType(CalendarStrip);
    final scrollable = find.descendant(of: strip, matching: find.byType(Scrollable));
    final weekWidth = tester.getSize(strip).width;

    await tester.fling(scrollable, const Offset(-800, 0), 3000);
    await tester.pumpAndSettle();

    final pixels = tester.state<ScrollableState>(scrollable).position.pixels;
    final ratio = pixels / weekWidth;
    expect((ratio - ratio.round()).abs(), lessThan(0.01), reason: '应落在整周边界，实际 $pixels');
  });

  testWidgets('快速甩动可以跨多周', (tester) async {
    await pumpApp(tester);

    final strip = find.byType(CalendarStrip);
    final scrollable = find.descendant(of: strip, matching: find.byType(Scrollable));
    final weekWidth = tester.getSize(strip).width;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await tester.fling(scrollable, const Offset(-200, 0), 6000);
    await tester.pumpAndSettle();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after - before, greaterThan(weekWidth * 2),
        reason: '快甩应该跨多周，实际只走了 ${(after - before) / weekWidth} 周');
  });

  testWidgets('翻一周时末端有过冲（能感知到"落页"）', (tester) async {
    await pumpApp(tester);

    final strip = find.byType(CalendarStrip);
    final scrollable = find.descendant(of: strip, matching: find.byType(Scrollable));
    double pixels() => tester.state<ScrollableState>(scrollable).position.pixels;
    final weekWidth = tester.getSize(strip).width;
    final before = pixels();

    await tester.fling(scrollable, const Offset(-60, 0), 1200);

    // 逐帧采样，抓动画过程中的最大位移
    double peak = before;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (pixels() > peak) peak = pixels();
    }
    await tester.pumpAndSettle();

    final after = pixels();
    expect(after - before, closeTo(weekWidth, 2.0), reason: '应落在一周之后');
    expect(peak - after, greaterThan(2.0),
        reason: '末端应有过冲（峰值 $peak / 落点 $after）—— 没有过冲就是平滑滑动，感知不到落页');
  });

  testWidgets('双击顶栏日期回到今天', (tester) async {
    await pumpApp(tester);

    final header = find.byKey(const Key('v6-header-date'));
    String label() => tester.widget<Text>(header).data!;

    final today = DateTime.now();
    final tomorrow = today.add(const Duration(days: 1));

    // 日历条里点明天（seed 在明天放了一条任务）
    await tester.tap(find
        .descendant(of: find.byType(CalendarStrip), matching: find.text('${tomorrow.day}'))
        .first);
    await settle(tester);
    expect(label(), contains('${tomorrow.day}日'));

    await tester.tap(header);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(header);
    await settle(tester);

    expect(label(), contains('${today.day}日'), reason: '双击顶栏应回到今天');
  });

  testWidgets('没有插件时：顶栏用默认格式，且没有徽章/附加行/标记', (tester) async {
    await pumpApp(tester);

    final today = DateTime.now();
    final weekday = <String>['一', '二', '三', '四', '五', '六', '日'][today.weekday - 1];
    expect(
      tester.widget<Text>(find.byKey(const Key('v6-header-date'))).data,
      '${today.month}月${today.day}日 周$weekday',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(ValueKey<String>('cal-mark-${dayKey(today)}')), findsNothing);
  });

  testWidgets('插槽：顶栏日期可被插件替换', (tester) async {
    SlotRegistry.instance.register(
      _FakeSlotProvider(<SlotId, SlotValue Function()>{
        SlotId.headerDate: () => const HeaderDateValue('农历九月初一'),
      }),
    );

    await pumpApp(tester);
    expect(find.text('农历九月初一'), findsOneWidget);
  });

  testWidgets('插槽：货币徽章可被插件点亮', (tester) async {
    SlotRegistry.instance.register(
      _FakeSlotProvider(<SlotId, SlotValue Function()>{
        SlotId.currencyBadge: () => const CurrencyBadgeValue(value: 120),
      }),
    );

    await pumpApp(tester);
    expect(find.text('120'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
  });

  testWidgets('插槽：日历标记画在对应日期上', (tester) async {
    final today = DateTime.now();
    SlotRegistry.instance.register(
      _FakeSlotProvider(<SlotId, SlotValue Function()>{
        SlotId.calendarMarks: () =>
            CalendarMarksValue(<DateTime, String>{DateTime(today.year, today.month, today.day): 'done'}),
      }),
    );

    await pumpApp(tester);
    expect(find.byKey(ValueKey<String>('cal-mark-${dayKey(today)}')), findsOneWidget);
  });

  testWidgets('插槽：任务卡片能多出一行', (tester) async {
    SlotRegistry.instance.register(
      _FakeSlotProvider(<SlotId, SlotValue Function()>{
        SlotId.taskCardExtra: () => const TaskCardExtraValue(taskId: 0, text: '已专注 3 次'),
      }),
    );

    await pumpApp(tester);
    expect(find.text('已专注 3 次'), findsWidgets);
  });
}
