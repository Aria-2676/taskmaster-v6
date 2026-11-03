import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/plugin/plugin_query_registry.dart';
import 'package:v5_app/core/plugin/plugin_query_scheduler.dart';

/// 假查询：按脚本返回预设结果，并记录被问过的插件。
class _FakeAsk {
  _FakeAsk(this.results);

  /// pluginId -> 依次返回的结果（用完就重复最后一个）
  final Map<String, List<QueryResult>> results;
  final List<String> calls = <String>[];

  Future<QueryResult> call(
    String pluginId,
    String method,
    Map<String, Object?> params,
  ) async {
    calls.add('$pluginId.$method');
    final queue = results[pluginId];
    if (queue == null || queue.isEmpty) return const QueryResult.unavailable();
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }
}

void main() {
  group('PluginQueryScheduler', () {
    test('并发问多个插件，各自结果都拿到', () async {
      final fake = _FakeAsk(<String, List<QueryResult>>{
        'plan_mode': <QueryResult>[
          const QueryResult.ok(<String, Object?>{'total': 3}),
        ],
        'list_mode': <QueryResult>[
          const QueryResult.ok(<String, Object?>{'total': 5}),
        ],
      });
      final scheduler = PluginQueryScheduler(ask: fake.call);

      final results = await scheduler.askAll('plan.list', <String>['plan_mode', 'list_mode']);

      expect(results.length, 2);
      expect(results['plan_mode']!.data!['total'], 3);
      expect(results['list_mode']!.data!['total'], 5);
    });

    test('连续 2 次超时后跳过它，不再浪费一次调用', () async {
      final fake = _FakeAsk(<String, List<QueryResult>>{
        'plan_mode': <QueryResult>[
          const QueryResult.timeout(),
          const QueryResult.timeout(),
        ],
      });
      final scheduler = PluginQueryScheduler(ask: fake.call, failureThreshold: 2);

      await scheduler.askAll('plan.list', <String>['plan_mode']);
      expect(scheduler.isSkipped('plan_mode'), isFalse);

      await scheduler.askAll('plan.list', <String>['plan_mode']);
      expect(scheduler.isSkipped('plan_mode'), isTrue);

      fake.calls.clear();
      await scheduler.askAll('plan.list', <String>['plan_mode']);
      expect(fake.calls, isEmpty, reason: '跳过之后就不该再问，否则每次都白等一个超时');
    });

    test('unsupported 不算失败：问多少次都不会被跳过', () async {
      final fake = _FakeAsk(<String, List<QueryResult>>{
        'energy_currency': <QueryResult>[const QueryResult.unsupported()],
      });
      final scheduler = PluginQueryScheduler(ask: fake.call, failureThreshold: 2);

      for (var i = 0; i < 5; i++) {
        await scheduler.askAll('plan.list', <String>['energy_currency']);
      }

      expect(
        scheduler.isSkipped('energy_currency'),
        isFalse,
        reason: '插件本来就没这个能力，把它跳过后用户再也看不到它',
      );
    });

    test('一次成功就把失败计数清零', () async {
      final fake = _FakeAsk(<String, List<QueryResult>>{
        'plan_mode': <QueryResult>[
          const QueryResult.timeout(),
          const QueryResult.ok(<String, Object?>{'total': 1}),
          const QueryResult.timeout(),
        ],
      });
      final scheduler = PluginQueryScheduler(ask: fake.call, failureThreshold: 2);

      await scheduler.askAll('plan.list', <String>['plan_mode']); // timeout
      await scheduler.askAll('plan.list', <String>['plan_mode']); // ok，清零
      await scheduler.askAll('plan.list', <String>['plan_mode']); // timeout（第 1 次）

      expect(scheduler.isSkipped('plan_mode'), isFalse, reason: '中间成功过一次就该重新计');
    });

    test('ask 抛异常不会让整批失败', () async {
      final scheduler = PluginQueryScheduler(
        ask: (id, method, params) async {
          if (id == 'bad') throw StateError('boom');
          return const QueryResult.ok(<String, Object?>{'total': 1});
        },
      );

      final results = await scheduler.askAll('plan.list', <String>['bad', 'good']);

      expect(results['bad']!.status, QueryStatus.failed);
      expect(results['good']!.isOk, isTrue);
    });
  });
}
