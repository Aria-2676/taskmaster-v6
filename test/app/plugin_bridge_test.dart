// 插件桥接（宿主侧）的契约测试。
//
// 重点在两件事：
//   1. **失败不抛异常**，一律返回 `{ok:false, error:{code,message}}`
//   2. **没声明权限就拿不到数据**，且插件之间的私有 KV 互不可见

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/plugin_bridge.dart';
import 'package:v5_app/app/data/settings_repository.dart';
import 'package:v5_app/app/data/task_repository.dart';
import 'package:v5_app/app/state/currency_store.dart';
import 'package:v5_app/app/models/task.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';
import 'package:v5_app/core/plugin/plugin_storage.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late TaskRepository tasks;
  late SettingsRepository settings;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    tasks = TaskRepository(db);
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  PluginBridge bridge({
    Set<String> permissions = const <String>{'task:read', 'tag:read'},
    String pluginId = 'demo_help',
    Set<HookId> hooks = const <HookId>{},
    EventJournal? journal,
    CurrencyStore? currency,
  }) =>
      PluginBridge(
        pluginId: pluginId,
        permissions: permissions,
        tasks: tasks,
        settings: settings,
        contract: 1,
        hooks: hooks,
        journal: journal,
        currency: currency,
      );

  Map<String, Object?> errorOf(Map<String, Object?> response) =>
      Map<String, Object?>.from(response['error']! as Map);

  test('没声明权限：返回 permission_denied，不抛异常', () async {
    final response = await bridge(permissions: const <String>{})
        .dispatch('task.count', <String, Object?>{'date': '2026-10-22'});

    expect(response['ok'], isFalse);
    expect(errorOf(response)['code'], 'permission_denied');
  });

  test('task.count 返回总数与已完成数', () async {
    final day = DateTime(2026, 10, 22);
    await tasks.insert(title: 'a', day: day);
    final done = await tasks.insert(title: 'b', day: day);
    await tasks.setDone(done, true);

    final response = await bridge().dispatch('task.count', <String, Object?>{'date': '2026-10-22'});

    expect(response['ok'], isTrue);
    final result = Map<String, Object?>.from(response['result']! as Map);
    expect(result['total'], 2);
    expect(result['done'], 1);
    expect(result['from'], '2026-10-22');
  });

  test('task.list 只给裁剪后的字段，并遵守 limit', () async {
    final day = DateTime(2026, 10, 22);
    for (var i = 0; i < 5; i++) {
      await tasks.insert(title: '任务 $i', day: day);
    }

    final response = await bridge().dispatch('task.list', <String, Object?>{
      'from': '2026-10-22',
      'to': '2026-10-22',
      'limit': 2,
    });

    final list = List<Object?>.from(response['result']! as List);
    expect(list, hasLength(2));

    final first = Map<String, Object?>.from(list.first! as Map);
    expect(first.keys.toSet(), <String>{
      'id',
      'title',
      'dueDate',
      'isDone',
      'priority',
      'estimatedMinutes',
      'tags',
    });
    expect(first.containsKey('description'), isFalse, reason: '不该把整行原样吐给插件');
  });

  test('tag.list 返回 id 与名称', () async {
    await tasks.insertTag(const Tag(id: 0, name: '工作'));
    final response = await bridge().dispatch('tag.list', const <String, Object?>{});

    final list = List<Object?>.from(response['result']! as List);
    expect(list, hasLength(1));
    expect(Map<String, Object?>.from(list.first! as Map)['name'], '工作');
  });

  test('私有 KV：换个插件 id 就读不到', () async {
    final mine = bridge();
    await mine.dispatch('store.set', <String, Object?>{'key': 'lastTab', 'value': 'stats'});

    final read = await mine.dispatch('store.get', <String, Object?>{'key': 'lastTab'});
    expect(Map<String, Object?>.from(read['result']! as Map)['value'], 'stats');

    final other = bridge(pluginId: 'another_plugin');
    final leaked = await other.dispatch('store.get', <String, Object?>{'key': 'lastTab'});
    expect(Map<String, Object?>.from(leaked['result']! as Map)['value'], isNull);
  });

  test('系统信息里带契约版本与已授予权限', () async {
    final response = await bridge(permissions: const <String>{'task:read'})
        .dispatch('system.info', const <String, Object?>{});

    final result = Map<String, Object?>.from(response['result']! as Map);
    expect(result['pluginId'], 'demo_help');
    expect(result['contract'], 1);
    expect(result['permissions'], <String>['task:read']);
  });

  test('未知方法与坏参数都走错误码，不抛', () async {
    final unknown = await bridge().dispatch('task.deleteEverything', const <String, Object?>{});
    expect(errorOf(unknown)['code'], 'unknown_method');

    final bad = await bridge().dispatch('task.list', <String, Object?>{
      'from': '2026-10-23',
      'to': '2026-10-22',
    });
    expect(errorOf(bad)['code'], 'bad_params');

    final missingKey = await bridge().dispatch('store.get', const <String, Object?>{});
    expect(errorOf(missingKey)['code'], 'bad_params');
  });

  // ================= 写权限 =================

  group('写权限', () {
    var changed = 0;

    setUp(() => changed = 0);

    PluginBridge writer({
      Set<String> permissions = const <String>{'task:read', 'tag:read', 'task:write'},
    }) =>
        PluginBridge(
          pluginId: 'demo_help',
          permissions: permissions,
          tasks: tasks,
          settings: settings,
          contract: 1,
          onChanged: () => changed++,
        );

    final day = DateTime(2026, 10, 22);

    test('没声明 task:write：建/改/标记完成全部被拒，且不写库', () async {
      final readOnly = writer(permissions: const <String>{'task:read'});

      for (final call in <List<Object?>>[
        <Object?>['task.create', <String, Object?>{'title': '偷写'}],
        <Object?>['task.update', <String, Object?>{'id': 1, 'title': '偷改'}],
        <Object?>['task.setDone', <String, Object?>{'id': 1, 'done': true}],
      ]) {
        final response = await readOnly.dispatch(call[0]! as String, call[1]! as Map<String, Object?>);
        expect(response['ok'], isFalse, reason: '${call[0]} 不该成功');
        expect(errorOf(response)['code'], 'permission_denied');
      }

      expect(await tasks.countTasks(), 0);
      expect(changed, 0, reason: '没写成就不该通知刷新');
    });

    test('task.delete 单独一条权限：只有 task:write 也删不了', () async {
      final id = await tasks.insert(title: '不该被删', day: day);
      final response = await writer().dispatch('task.delete', <String, Object?>{'id': id});

      expect(errorOf(response)['code'], 'permission_denied');
      expect(await tasks.countTasks(), 1);
    });

    test('task.create 落库并返回 id，且通知宿主刷新', () async {
      final response = await writer().dispatch('task.create', <String, Object?>{
        'title': '  插件建的  ',
        'date': '2026-10-22',
        'priority': 'orange',
        'estimatedMinutes': 45,
        'description': '来自插件',
      });

      expect(response['ok'], isTrue);
      final id = Map<String, Object?>.from(response['result']! as Map)['id'];
      expect(id, isA<int>());
      expect(changed, 1);

      final created = (await tasks.tasksOn(day)).single;
      expect(created.title, '插件建的', reason: '首尾空白要 trim');
      expect(created.priority, 'orange');
      expect(created.estimatedMinutes, 45);
      expect(created.description, '来自插件');
    });

    test('task.create 不传 date 时算今天', () async {
      await writer().dispatch('task.create', <String, Object?>{'title': '今天'});
      final today = DateTime.now();
      expect(await tasks.countTasks(), 1);
      expect(
        (await tasks.tasksOn(today)).single.title,
        '今天',
      );
    });

    test('create 的入参一律校验，坏输入不落库', () async {
      final cases = <Map<String, Object?>>[
        <String, Object?>{'title': ''},
        <String, Object?>{'title': '   '},
        <String, Object?>{'title': 'x' * 201},
        <String, Object?>{'title': 'ok', 'priority': 'purple'},
        <String, Object?>{'title': 'ok', 'date': '2026-13-01'},
        <String, Object?>{'title': 'ok', 'date': '2026/10/22'},
        <String, Object?>{'title': 'ok', 'estimatedMinutes': -5},
        <String, Object?>{'title': 'ok', 'estimatedMinutes': 99999},
        <String, Object?>{'title': 'ok', 'tagIds': <Object?>[999]},
        <String, Object?>{'title': 'ok', 'tagIds': 'not-a-list'},
      ];

      for (final params in cases) {
        final response = await writer().dispatch('task.create', params);
        expect(response['ok'], isFalse, reason: '应该拒绝：$params');
        expect(errorOf(response)['code'], 'bad_params');
      }
      expect(await tasks.countTasks(), 0);
    });

    test('task.update 只改传入的字段，其余不动', () async {
      final id = await tasks.insert(
        title: '原标题',
        day: day,
        description: '原描述',
        priority: 'blue',
        estimatedMinutes: 30,
      );

      final response = await writer().dispatch('task.update', <String, Object?>{
        'id': id,
        'title': '新标题',
      });
      expect(response['ok'], isTrue);

      final task = (await tasks.tasksOn(day)).single;
      expect(task.title, '新标题');
      expect(task.description, '原描述', reason: '没传就不该被清空');
      expect(task.priority, 'blue');
      expect(task.estimatedMinutes, 30);
    });

    test('task.update 可以把估时/描述显式清成 null', () async {
      final id = await tasks.insert(title: 'x', day: day, description: '有', estimatedMinutes: 30);

      await writer().dispatch('task.update', <String, Object?>{
        'id': id,
        'estimatedMinutes': null,
        'description': null,
      });

      final task = (await tasks.tasksOn(day)).single;
      expect(task.estimatedMinutes, isNull);
      expect(task.description, isNull);
    });

    test('task.update 换标签是整体替换', () async {
      await tasks.insertTag(const Tag(id: 0, name: '工作'));
      await tasks.insertTag(const Tag(id: 0, name: '学习'));
      final all = await tasks.allTags();
      final work = all.firstWhere((t) => t.name == '工作').id;
      final study = all.firstWhere((t) => t.name == '学习').id;

      final id = await tasks.insert(title: 'x', day: day, tagIds: <int>[work]);
      await writer().dispatch('task.update', <String, Object?>{
        'id': id,
        'tagIds': <int>[study],
      });

      final task = (await tasks.tasksOn(day)).single;
      expect(task.tags.map((t) => t.name), <String>['学习']);
    });

    test('task.update 不存在的 id 回 not_found，不静默成功', () async {
      final response = await writer().dispatch('task.update', <String, Object?>{
        'id': 9999,
        'title': '幽灵',
      });
      expect(errorOf(response)['code'], 'not_found');
    });

    test('task.update 什么字段都没传：回 bad_params', () async {
      final id = await tasks.insert(title: 'x', day: day);
      final response = await writer().dispatch('task.update', <String, Object?>{'id': id});
      expect(errorOf(response)['code'], 'bad_params');
    });

    test('task.setDone 改完成态并通知刷新', () async {
      final id = await tasks.insert(title: 'x', day: day);
      final response = await writer().dispatch('task.setDone', <String, Object?>{
        'id': id,
        'done': true,
      });

      expect(response['ok'], isTrue);
      final task = (await tasks.tasksOn(day)).single;
      expect(task.isDone, isTrue);
      expect(task.completedAt, isNotNull);
      expect(changed, 1);

      final bad = await writer().dispatch('task.setDone', <String, Object?>{
        'id': id,
        'done': 'yes',
      });
      expect(errorOf(bad)['code'], 'bad_params');
    });

    test('task.delete 跟随用户设置：开回收站就进回收站', () async {
      await settings.setBool(SettingsKeys.recycleBinEnabled, true);
      final id = await tasks.insert(title: '要删的', day: day);

      final response = await writer(
        permissions: const <String>{'task:delete'},
      ).dispatch('task.delete', <String, Object?>{'id': id});

      expect(response['ok'], isTrue);
      expect((response['result']! as Map)['toRecycle'], isTrue);
      expect(await tasks.countTasks(), 0);
      expect(await tasks.recycledCount(), 1, reason: '应该躺在回收站里，能恢复');
    });

    test('task.delete 关着回收站就是物理删除', () async {
      final id = await tasks.insert(title: '要删的', day: day);

      await writer(permissions: const <String>{'task:delete'})
          .dispatch('task.delete', <String, Object?>{'id': id});

      expect(await tasks.countTasks(), 0);
      expect(await tasks.recycledCount(), 0);
    });
  });

  // ================= 事件补发 =================

  group('事件补发', () {
    late EventJournal journal;

    setUp(() => journal = EventJournal(db));

    Future<void> seed() async {
      await journal.record(HookEvent(
        hook: HookId.taskCompleted,
        payload: <String, Object?>{'taskId': 1, 'title': '完成了一条'},
      ));
      await journal.record(HookEvent(
        hook: HookId.taskRecycled,
        payload: <String, Object?>{'taskId': 2, 'title': '删掉了一条'},
      ));
    }

    test('没有 task:read：拿不到事件（payload 就是任务数据）', () async {
      await seed();
      final response = await bridge(
        permissions: const <String>{'task:write'},
        hooks: <HookId>{HookId.taskCompleted},
        journal: journal,
      ).dispatch('event.pending', const <String, Object?>{});

      expect(errorOf(response)['code'], 'permission_denied');
    });

    test('pending 的字段名是 event（插件靠它分发），payload 是对象', () async {
      await seed();
      final response = await bridge(
        hooks: <HookId>{HookId.taskCompleted},
        journal: journal,
      ).dispatch('event.pending', const <String, Object?>{});

      final list = (response['result']! as List).cast<Map<String, Object?>>();
      expect(list, hasLength(1));

      final first = list.single;
      // 这条断言是拿真机 bug 换来的：插件里写成 evt.hook 时条件永远为假，
      // 事件被 ack 掉了、奖励却没发，而且表面上没有任何错误。
      expect(first['event'], 'task.completed');
      expect(first.containsKey('hook'), isFalse,
          reason: '插件按 event 分发；多一个 hook 只会让人写错');
      expect(first['payload'], isA<Map>(), reason: 'payload 必须是对象，不能是 JSON 字符串');
      expect((first['payload']! as Map)['title'], '完成了一条');
    });

    test('没声明 hooks：返回空数组，不是报错', () async {
      await seed();
      final response = await bridge(journal: journal)
          .dispatch('event.pending', const <String, Object?>{});

      expect(response['ok'], isTrue);
      expect(List<Object?>.from(response['result']! as List), isEmpty);
    });

    test('只返回声明过的钩子，并带上 id 供 ack', () async {
      await seed();
      final response = await bridge(
        hooks: <HookId>{HookId.taskCompleted},
        journal: journal,
      ).dispatch('event.pending', const <String, Object?>{});

      final list = List<Object?>.from(response['result']! as List);
      expect(list, hasLength(1));
      final event = Map<String, Object?>.from(list.first! as Map);
      expect(event['event'], 'task.completed');
      expect(event['id'], isA<int>());
      expect(
        Map<String, Object?>.from(event['payload']! as Map)['title'],
        '完成了一条',
      );
    });

    test('ack 之后不再返回', () async {
      await seed();
      final b = bridge(hooks: <HookId>{HookId.taskCompleted}, journal: journal);

      final first = await b.dispatch('event.pending', const <String, Object?>{});
      final ids = <int>[
        for (final item in List<Object?>.from(first['result']! as List))
          (item! as Map)['id']! as int,
      ];

      final ack = await b.dispatch('event.ack', <String, Object?>{'ids': ids});
      expect((ack['result']! as Map)['acked'], 1);

      final again = await b.dispatch('event.pending', const <String, Object?>{});
      expect(List<Object?>.from(again['result']! as List), isEmpty);
    });

    test('ack 参数不合法：回 bad_params，不静默清空', () async {
      final b = bridge(hooks: <HookId>{HookId.taskCompleted}, journal: journal);

      for (final params in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'ids': <Object?>[]},
        <String, Object?>{'ids': 'not-a-list'},
        <String, Object?>{'ids': <Object?>[-1]},
      ]) {
        final response = await b.dispatch('event.ack', params);
        expect(errorOf(response)['code'], 'bad_params', reason: '应该拒绝：$params');
      }
    });

    test('没接 journal（宿主降级）：pending 返回空而不是崩', () async {
      final response = await bridge(hooks: <HookId>{HookId.taskCompleted})
          .dispatch('event.pending', const <String, Object?>{});

      expect(response['ok'], isTrue);
      expect(List<Object?>.from(response['result']! as List), isEmpty);
    });
  });

  // ================= 插件私有数据 =================

  group('插件私有数据', () {
    late PluginStorageSpec spec;

    setUp(() async {
      spec = PluginStorageSpec.fromJson(<String, Object?>{
        'tables': <Object?>[
          <String, Object?>{
            'name': 'entries',
            'columns': <Object?>[
              <String, Object?>{'name': 'day', 'type': 'text'},
              <String, Object?>{'name': 'body', 'type': 'text'},
            ],
          },
        ],
      });
      final registry = PluginSchemaRegistry();
      registry.registerStorage('demo_help', spec);
      await registry.materialize(db);
    });

    PluginBridge withData() => PluginBridge(
          pluginId: 'demo_help',
          permissions: const <String>{'task:read'},
          tasks: tasks,
          settings: settings,
          contract: 1,
          data: PluginDataStore(db: db, pluginId: 'demo_help', spec: spec),
        );

    test('没声明 storage：db.* 回 no_storage，不是静默失败', () async {
      for (final method in <String>[
        'db.insert',
        'db.select',
        'db.update',
        'db.delete',
        'db.aggregate',
      ]) {
        final response = await bridge().dispatch(method, <String, Object?>{
          'table': 'entries',
          'values': <String, Object?>{'day': 'x'},
          'metrics': <Object?>[],
        });
        expect(errorOf(response)['code'], 'no_storage', reason: '$method 应该明确拒绝');
      }
    });

    test('写一条再查回来', () async {
      final inserted = await withData().dispatch('db.insert', <String, Object?>{
        'table': 'entries',
        'values': <String, Object?>{'day': '2026-10-27', 'body': '今天'},
      });
      expect(inserted['ok'], isTrue);

      final selected = await withData().dispatch('db.select', <String, Object?>{
        'table': 'entries',
      });
      final rows = List<Object?>.from(selected['result']! as List);
      expect(rows, hasLength(1));
      expect(Map<String, Object?>.from(rows.first! as Map)['body'], '今天');
    });

    test('表名/参数不合法：bad_params（错误码要能区分"你写错了"和"宿主崩了"）', () async {
      final badTable = await withData().dispatch('db.select', <String, Object?>{
        'table': 'tasks',
      });
      expect(errorOf(badTable)['code'], 'bad_params');

      final badValues = await withData().dispatch('db.insert', <String, Object?>{
        'table': 'entries',
        'values': 'not-a-map',
      });
      expect(errorOf(badValues)['code'], 'bad_params');

      final noMetrics = await withData().dispatch('db.aggregate', <String, Object?>{
        'table': 'entries',
        'metrics': <Object?>[],
      });
      expect(errorOf(noMetrics)['code'], 'bad_params');
    });

    test('聚合能直接算出来（统计插件的基础）', () async {
      for (final row in <Map<String, Object?>>[
        <String, Object?>{'day': '2026-10-26', 'body': 'a'},
        <String, Object?>{'day': '2026-10-26', 'body': 'b'},
        <String, Object?>{'day': '2026-10-27', 'body': 'c'},
      ]) {
        await withData().dispatch('db.insert', <String, Object?>{'table': 'entries', 'values': row});
      }

      final response = await withData().dispatch('db.aggregate', <String, Object?>{
        'table': 'entries',
        'groupBy': <String>['day'],
        'metrics': <Object?>[
          <String, Object?>{'fn': 'count', 'column': '*', 'as': 'n'},
        ],
      });

      final rows = List<Object?>.from(response['result']! as List);
      expect(rows, hasLength(2));
      final first = Map<String, Object?>.from(rows.first! as Map);
      expect(first['day'], '2026-10-26');
      expect(first['n'], 2);
    });
  });

  group('货币', () {
    late CurrencyStore currency;

    setUp(() async {
      currency = CurrencyStore(settings);
      await currency.load();
    });

    test('没声明 currency:read 读不了', () async {
      final response = await bridge(currency: currency)
          .dispatch('currency.get', const <String, Object?>{});
      expect(errorOf(response)['code'], 'permission_denied');
    });

    test('读到的是自己的余额，第一次写入就成为当前货币', () async {
      final bridge0 = bridge(
        currency: currency,
        permissions: const <String>{'currency:read', 'currency:write'},
      );

      final before = await bridge0.dispatch('currency.get', const <String, Object?>{});
      expect((before['result']! as Map)['amount'], 0);
      expect((before['result']! as Map)['active'], isFalse);

      final set = await bridge0.dispatch(
        'currency.set',
        <String, Object?>{'amount': 120},
      );
      expect(set['ok'], isTrue);
      expect(currency.providerId, 'demo_help');
      expect(currency.balance, 120);

      final after = await bridge0.dispatch('currency.get', const <String, Object?>{});
      expect((after['result']! as Map)['amount'], 120);
      expect((after['result']! as Map)['active'], isTrue);
    });

    test('看不到别的插件的余额', () async {
      await currency.report('other', 999);

      final response = await bridge(
        currency: currency,
        permissions: const <String>{'currency:read'},
      ).dispatch('currency.get', const <String, Object?>{});

      expect((response['result']! as Map)['amount'], 0,
          reason: '只返回自己的镜像，不泄露别人的');
    });

    test('坏参数一律拒绝，不落库', () async {
      final b = bridge(
        currency: currency,
        permissions: const <String>{'currency:write'},
      );

      for (final bad in <Object?>['120', 12.5, -1, null, 200000000]) {
        final response = await b.dispatch(
          'currency.set',
          <String, Object?>{'amount': bad},
        );
        expect(errorOf(response)['code'], 'bad_params', reason: 'amount=$bad');
      }
      expect(currency.installed, isFalse);
    });

    test('宿主没接货币时明确报错，而不是假装成功', () async {
      final response = await bridge(
        permissions: const <String>{'currency:write'},
      ).dispatch('currency.set', <String, Object?>{'amount': 10});

      expect(errorOf(response)['code'], 'bad_params');
      expect(errorOf(response)['message'], contains('没有接入货币'));
    });
  });
}
