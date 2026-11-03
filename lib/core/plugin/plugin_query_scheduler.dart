import 'package:flutter/foundation.dart';

import 'plugin_query_registry.dart';

/// 并发查询多个插件，并记住"哪个一直答不上来"。
///
/// 两件事合在一起，是因为它们服务于同一个目标：**今日页/全局搜索不能因为
/// 一个插件卡住就转圈**。超时在单次查询里已经兜住了，这里管的是"同一个插件
/// 反复超时就别再问了"。
class PluginQueryScheduler {
  PluginQueryScheduler({
    required this.ask,
    this.failureThreshold = 2,
  });

  /// 实际发起查询的函数。生产环境传 `PluginQueryRegistry.instance.query`，
  /// 测试里传假实现 —— 这样"连续失败就跳过"这条逻辑可以单独验。
  final Future<QueryResult> Function(
    String pluginId,
    String method,
    Map<String, Object?> params,
  ) ask;

  /// 连续失败几次后本会话不再问它。
  final int failureThreshold;

  final Map<String, int> _consecutiveFailures = <String, int>{};
  final Set<String> _skipped = <String>{};

  bool isSkipped(String pluginId) => _skipped.contains(pluginId);

  /// 并发问一批插件。
  ///
  /// 返回 Map 里**不含被跳过的插件**（调用方据此判断"这块没接入/暂时不问了"）。
  /// 单个插件失败不影响其他的：`Future.wait` 里每个分支自己捕获，不会冒泡。
  Future<Map<String, QueryResult>> askAll(
    String method,
    Iterable<String> pluginIds, {
    Map<String, Object?> params = const <String, Object?>{},
  }) async {
    final targets = pluginIds.where((id) => !isSkipped(id)).toList(growable: false);
    if (targets.isEmpty) return <String, QueryResult>{};

    final entries = await Future.wait(
      targets.map((id) async {
        QueryResult result;
        try {
          result = await ask(id, method, params);
        } catch (error) {
          debugPrint('[query-scheduler] $id.$method 抛异常：$error');
          result = const QueryResult.failed();
        }
        _record(id, result);
        return MapEntry<String, QueryResult>(id, result);
      }),
    );
    return Map<String, QueryResult>.fromEntries(entries);
  }

  void _record(String pluginId, QueryResult result) {
    if (result.isOk) {
      _consecutiveFailures.remove(pluginId);
      _skipped.remove(pluginId);
      return;
    }
    // `unsupported` 不算失败：插件没承诺过这个能力，把它记成失败会让
    // "本就不支持"变成"被永久跳过"，用户再也看不到它。
    if (!result.countsAsFailure) return;
    final next = (_consecutiveFailures[pluginId] ?? 0) + 1;
    _consecutiveFailures[pluginId] = next;
    if (next >= failureThreshold) _skipped.add(pluginId);
  }

  /// 清空失败记忆（用户下拉刷新、或切走再回来时调）。
  void reset() {
    _consecutiveFailures.clear();
    _skipped.clear();
  }
}
