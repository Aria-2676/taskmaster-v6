// 事件日志：**没挂载的插件，事件不许丢**。
//
// 这块的失败模式很隐蔽：事件看起来"发出去了"（有日志、有测试），
// 但插件下次上来捞不到，或者捞到了重复的导致重复发奖。
// 所以两头都要盯：不丢、也不重复投递到没法去重。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/event_journal.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late EventJournal journal;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    addTearDown(db.close);
    journal = EventJournal(db);
  });

  HookEvent completed(String title) => HookEvent(
        hook: HookId.taskCompleted,
        payload: <String, Object?>{'taskId': 1, 'title': title},
      );

  group('记录与投递', () {
    test('记一条，捞得到，顺序是先进先出', () async {
      await journal.record(completed('第一条'));
      await journal.record(completed('第二条'));

      final events = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(events, hasLength(2));
      expect(events.first.payload['title'], '第一条');
      expect(events.last.payload['title'], '第二条');
      expect(events.first.hook, HookId.taskCompleted);
    });

    test('只给插件声明过的钩子', () async {
      await journal.record(completed('完成'));
      await journal.record(HookEvent(
        hook: HookId.taskRecycled,
        payload: <String, Object?>{'title': '删掉'},
      ));

      final onlyCompleted = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(onlyCompleted.map((e) => e.payload['title']), <String>['完成']);
    });

    test('没声明任何钩子：一条都不给', () async {
      await journal.record(completed('x'));
      expect(await journal.pending(const <HookId>{}), isEmpty);
    });

    test('ack 之后不再投递（否则插件会重复处理）', () async {
      await journal.record(completed('a'));
      await journal.record(completed('b'));

      final first = await journal.pending(<HookId>{HookId.taskCompleted});
      final acked = await journal.ack(<int>[first.first.id]);
      expect(acked, 1);

      final rest = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(rest, hasLength(1));
      expect(rest.single.payload['title'], 'b');
      expect(await journal.count(), 1);
    });

    test('since 分页：只拿比它新的', () async {
      await journal.record(completed('a'));
      final firstBatch = await journal.pending(<HookId>{HookId.taskCompleted});
      await journal.record(completed('b'));

      final next = await journal.pending(
        <HookId>{HookId.taskCompleted},
        since: firstBatch.first.id,
      );
      expect(next.single.payload['title'], 'b');
    });

    test('payload 存的是快照：事后改对象不影响已记录的事件', () async {
      final payload = <String, Object?>{'taskId': 1, 'title': '原名'};
      await journal.record(HookEvent(hook: HookId.taskCompleted, payload: payload));
      payload['title'] = '改过了';

      final events = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(events.single.payload['title'], '原名');
    });
  });

  group('容量与容错', () {
    test('超过上限删最老的，不让没人 ack 的插件撑大库', () async {
      final small = EventJournal(db, maxRows: 3);
      for (var i = 1; i <= 5; i++) {
        await small.record(completed('第 $i 条'));
      }
      expect(await small.count(), 3);

      final events = await small.pending(<HookId>{HookId.taskCompleted});
      expect(events.map((e) => e.payload['title']), <String>['第 3 条', '第 4 条', '第 5 条']);
    });

    test('库里有坏 payload：跳过内容而不是整批失败', () async {
      await db.insert(V6Table.pluginEvents, <String, Object?>{
        PluginEventCol.hook: HookId.taskCompleted.id,
        PluginEventCol.payload: '{not json',
        PluginEventCol.createdAt: DateTime.now().toUtc().toIso8601String(),
      });

      final events = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(events, hasLength(1));
      expect(events.single.payload, isEmpty, reason: '解析不出来就给空 map，别抛');
    });

    test('宿主不认识的钩子写在表里：直接跳过', () async {
      await db.insert(V6Table.pluginEvents, <String, Object?>{
        PluginEventCol.hook: 'future.event',
        PluginEventCol.payload: jsonEncode(<String, Object?>{'a': 1}),
        PluginEventCol.createdAt: DateTime.now().toUtc().toIso8601String(),
      });

      expect(await journal.pending(<HookId>{HookId.taskCompleted}), isEmpty);
    });

    test('注册成 HookListener 后会自动落库', () async {
      HookBus.instance.clear();
      HookBus.instance.register(journal);
      addTearDown(HookBus.instance.clear);

      await HookBus.instance.emit(
        HookId.taskCompleted,
        payload: <String, Object?>{'title': '钩子发来的'},
      );
      // onEvent 是异步的，等它写库
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final events = await journal.pending(<HookId>{HookId.taskCompleted});
      expect(events, hasLength(1));
      expect(events.single.payload['title'], '钩子发来的');
    });
  });
}
