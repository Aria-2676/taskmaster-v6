// 事件推送给插件：声明解析 + 通道行为。
//
// 这里最容易出的两个问题都不是崩溃：
//   - 事件在页面加载完之前到 → 静默丢失（用户以为插件不工作）
//   - 插件没声明却收到了 → 契约形同虚设
// 所以每条都盯住"什么时候发"和"能不能发"。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/extension/extension_hook.dart';
import 'package:v5_app/core/plugin/plugin_hook_channel.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';

void main() {
  group('manifest 里的 hooks', () {
    Map<String, Object?> manifestJson(Object? hooks) => <String, Object?>{
          'id': 'demo_help',
          'name': '使用说明',
          'version': '1.0.0',
          'contract': 1,
          'entry': 'index.html',
          'hooks': hooks,
        };

    test('认识的钩子被解析', () {
      final manifest = PluginManifest.parse(
        manifestJson(<String>['task.completed', 'task.recycled']),
      );
      expect(manifest.hooks, <HookId>{HookId.taskCompleted, HookId.taskRecycled});
    });

    test('不认识的钩子忽略，但插件照常可装', () {
      final manifest = PluginManifest.parse(
        manifestJson(<String>['task.completed', 'future.event']),
      );
      expect(manifest.hooks, <HookId>{HookId.taskCompleted});
    });

    test('不写 hooks 就是空集（老插件不受影响）', () {
      expect(PluginManifest.parse(manifestJson(null)).hooks, isEmpty);
      expect(PluginManifest.parse(manifestJson('not-a-list')).hooks, isEmpty);
    });
  });

  group('PluginHookChannel', () {
    late List<String> sent;

    PluginHookChannel channel({Set<HookId>? hooks, int maxQueued = 20}) =>
        PluginHookChannel(
          pluginId: 'demo_help',
          hooks: hooks ?? <HookId>{HookId.taskCompleted},
          send: (event, payload) => sent.add('$event:${payload['taskId']}'),
          maxQueued: maxQueued,
        );

    HookEvent completed(int id) => HookEvent(
          hook: HookId.taskCompleted,
          payload: <String, Object?>{'taskId': id},
        );

    setUp(() => sent = <String>[]);

    test('页面没加载完：先排队，不丢也不急着发', () async {
      final c = channel();
      await c.onEvent(completed(1));
      await c.onEvent(completed(2));

      expect(sent, isEmpty);
      expect(c.queued, 2);
    });

    test('加载完成后按顺序补发', () async {
      final c = channel();
      await c.onEvent(completed(1));
      await c.onEvent(completed(2));

      c.markReady();

      expect(sent, <String>['task.completed:1', 'task.completed:2']);
      expect(c.queued, 0);
    });

    test('加载完成后新事件立刻发', () async {
      final c = channel();
      c.markReady();
      await c.onEvent(completed(7));

      expect(sent, <String>['task.completed:7']);
    });

    test('没声明的钩子不排队也不发', () async {
      final c = channel(hooks: <HookId>{HookId.taskRecycled});
      c.markReady();

      await c.onEvent(completed(1));
      expect(sent, isEmpty);
      expect(c.queued, 0);
    });

    test('队列有上限：满了丢最老的，不让坏插件吃内存', () async {
      final c = channel(maxQueued: 3);
      for (var i = 1; i <= 5; i++) {
        await c.onEvent(completed(i));
      }
      expect(c.queued, 3);

      c.markReady();
      expect(sent, <String>['task.completed:3', 'task.completed:4', 'task.completed:5']);
    });

    test('页面重载：回到排队状态，不往旧上下文里发', () async {
      final c = channel();
      c.markReady();
      await c.onEvent(completed(1));
      expect(sent, hasLength(1));

      c.markUnready();
      await c.onEvent(completed(2));
      expect(sent, hasLength(1), reason: '重载期间不该往旧页面发');
      expect(c.queued, 1);

      c.markReady();
      expect(sent, <String>['task.completed:1', 'task.completed:2']);
    });

    test('发送本身抛异常：吞掉，不把主流程拖崩', () async {
      final c = PluginHookChannel(
        pluginId: 'demo_help',
        hooks: <HookId>{HookId.taskCompleted},
        send: (_, __) => throw StateError('page gone'),
      );
      c.markReady();

      await expectLater(c.onEvent(completed(1)), completes);
      c.markReady(); // 队列补发里抛异常也不能冒出来
    });
  });
}
