// 事件钩子的发点测试。
//
// 这一层最容易出的不是崩溃，而是**多发了**或者**漏发了**：
//   - 多发：货币插件会把同一次完成算成两次奖励
//   - 漏发：插件永远收不到"任务完成了"，功能看起来就是坏的
// 所以每条都同时验"发了"和"没发"。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_bridge.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/app/state/task_store.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';

/// 收集事件，不做事。
class _Collector implements HookListener {
  _Collector(this.hooks);

  final Set<HookId> hooks;
  final List<HookEvent> events = <HookEvent>[];

  @override
  String get pluginId => 'test_collector';

  @override
  Future<void> onEvent(HookEvent event) async => events.add(event);

  List<HookEvent> of(HookId hook) => events.where((e) => e.hook == hook).toList();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository repo;
  late SettingsRepository settings;
  late TaskStore store;
  late _Collector collector;
  final day = DateTime(2026, 10, 26);

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);

    repo = TaskRepository(db);
    settings = SettingsRepository(db);
    store = TaskStore(repo, settings);
    await store.load(day);

    HookBus.instance.clear();
    collector = _Collector(HookId.values.toSet());
    HookBus.instance.register(collector);
  });

  tearDown(() => HookBus.instance.clear());

  group('主包自己改任务', () {
    test('勾完成：发 task.completed，payload 里有算奖励要用的字段', () async {
      await repo.insert(title: '写周报', day: day, priority: 'red', estimatedMinutes: 30);
      await store.load(day);

      await store.toggle(store.tasks.single);
      // emit 是 unawaited 的，等它落地
      await Future<void>.delayed(Duration.zero);

      final events = collector.of(HookId.taskCompleted);
      expect(events, hasLength(1));
      expect(events.single.payload['title'], '写周报');
      expect(events.single.payload['estimatedMinutes'], 30);
      expect(events.single.payload['priority'], 'red');
      expect(events.single.payload['dueDate'], '2026-10-26');
      expect(events.single.payload.containsKey('description'), isFalse,
          reason: '描述是用户写给自己的，不该进事件');
    });

    test('取消完成：不发 completed（否则等于可以刷奖励）', () async {
      final id = await repo.insert(title: 'x', day: day);
      await repo.setDone(id, true);
      await store.load(day);

      await store.toggle(store.tasks.single);
      await Future<void>.delayed(Duration.zero);

      expect(collector.of(HookId.taskCompleted), isEmpty);
    });

    test('开回收站时删除：发 task.recycled', () async {
      await store.setRecycleBinEnabled(true);
      final id = await repo.insert(title: '要删的', day: day);
      await store.load(day);

      await store.remove(store.tasks.single);
      await Future<void>.delayed(Duration.zero);

      expect(collector.of(HookId.taskRecycled), hasLength(1));
      expect(collector.of(HookId.taskRecycled).single.payload['title'], '要删的');
      expect(id, isPositive);
    });

    test('关回收站时删除：不发事件（物理删除没有可操作对象）', () async {
      await store.setRecycleBinEnabled(false);
      await repo.insert(title: '要删的', day: day);
      await store.load(day);

      await store.remove(store.tasks.single);
      await Future<void>.delayed(Duration.zero);

      expect(collector.of(HookId.taskRecycled), isEmpty);
    });
  });

  group('插件通过 bridge 改任务', () {
    PluginBridge writer({Set<String> permissions = const <String>{'task:write', 'task:delete'}}) =>
        PluginBridge(
          pluginId: 'demo_help',
          version: '1.0.0',
          permissions: permissions,
          tasks: repo,
          settings: settings,
          contract: 1,
        );

    test('setDone(true) 发一次 completed；重复调用不再发', () async {
      final id = await repo.insert(title: '插件完成', day: day, estimatedMinutes: 15);

      await writer().dispatch('task.setDone', <String, Object?>{'id': id, 'done': true});
      await Future<void>.delayed(Duration.zero);
      expect(collector.of(HookId.taskCompleted), hasLength(1));

      // 插件页面刷新时可能重放一次 —— 不能因此再发一次奖励
      await writer().dispatch('task.setDone', <String, Object?>{'id': id, 'done': true});
      await Future<void>.delayed(Duration.zero);
      expect(collector.of(HookId.taskCompleted), hasLength(1));
    });

    test('setDone(false) 不发 completed', () async {
      final id = await repo.insert(title: 'x', day: day);
      await repo.setDone(id, true);

      await writer().dispatch('task.setDone', <String, Object?>{'id': id, 'done': false});
      await Future<void>.delayed(Duration.zero);

      expect(collector.of(HookId.taskCompleted), isEmpty);
    });

    test('delete 跟着用户设置走：进回收站时发 recycled', () async {
      await settings.setBool(SettingsKeys.recycleBinEnabled, true);
      final id = await repo.insert(title: '插件删的', day: day);

      await writer().dispatch('task.delete', <String, Object?>{'id': id});
      await Future<void>.delayed(Duration.zero);

      final events = collector.of(HookId.taskRecycled);
      expect(events, hasLength(1));
      expect(events.single.payload['title'], '插件删的');
    });

    test('delete 物理删除时不发事件', () async {
      await settings.setBool(SettingsKeys.recycleBinEnabled, false);
      final id = await repo.insert(title: 'x', day: day);

      await writer().dispatch('task.delete', <String, Object?>{'id': id});
      await Future<void>.delayed(Duration.zero);

      expect(collector.of(HookId.taskRecycled), isEmpty);
    });
  });

  group('钩子本身不拖垮主流程', () {
    test('订阅方抛异常：主流程照常完成，其他订阅方照常收到', () async {
      HookBus.instance.clear();

      final bad = _ThrowingListener();
      final good = _Collector(<HookId>{HookId.taskCompleted});
      HookBus.instance.register(bad);
      HookBus.instance.register(good);

      final id = await repo.insert(title: 'x', day: day);
      await repo.setDone(id, true);
      await HookBus.instance.emit(HookId.taskCompleted, payload: <String, Object?>{'taskId': id});

      expect(good.of(HookId.taskCompleted), hasLength(1), reason: '坏的不能连累好的');
    });
  });
}

class _ThrowingListener implements HookListener {
  @override
  String get pluginId => 'test_throwing';

  @override
  Set<HookId> get hooks => HookId.values.toSet();

  @override
  Future<void> onEvent(HookEvent event) async => throw StateError('boom');
}
