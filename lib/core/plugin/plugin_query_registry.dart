import 'package:flutter/foundation.dart';

/// 一次查询的结果。**不返回裸 Map**：调用方要能区分"这个插件没实现"和
/// "实现了但超时/报错" —— 前者不该被记成失败（否则连续两次就把一个
/// 本来就不支持该查询的插件永久跳过），后者才该。
enum QueryStatus {
  /// 拿到了数据。
  ok,

  /// 插件没注册这个方法（`queryEntry` 没写，或写了但没实现这个 method）。
  /// **不算失败**，不参与失败计数。
  unsupported,

  /// 超过等待上限。
  timeout,

  /// 插件处理时抛了异常。
  failed,

  /// 没有能回答它的东西（页面不在、离屏没起来）。
  unavailable,
}

@immutable
class QueryResult {
  const QueryResult(this.status, [this.data]);

  const QueryResult.ok(Map<String, Object?> data) : this(QueryStatus.ok, data);
  const QueryResult.unsupported() : this(QueryStatus.unsupported);
  const QueryResult.timeout() : this(QueryStatus.timeout);
  const QueryResult.failed() : this(QueryStatus.failed);
  const QueryResult.unavailable() : this(QueryStatus.unavailable);

  final QueryStatus status;
  final Map<String, Object?>? data;

  bool get isOk => status == QueryStatus.ok;

  /// 是否该计入"连续失败"。
  ///
  /// `unsupported` 明确排除：插件从来没承诺过这个能力，记成失败会让
  /// 一个正常的不支持状态在两次之后变成"永久跳过"，用户再也不会看到它。
  bool get countsAsFailure =>
      status == QueryStatus.timeout ||
      status == QueryStatus.failed ||
      status == QueryStatus.unavailable;
}

/// 插件向主包暴露"查询"能力的注册表。
///
/// 数据仍然是各插件自己的（`plg_<id>_*`），主包不直读表 —— 要数据就问，
/// 由插件的 WebView（前台页面或离屏）回答。
/// 这是 `docs/decisions.md`「请求式查询」的落地入口。
class PluginQueryRegistry {
  PluginQueryRegistry._();

  static final PluginQueryRegistry instance = PluginQueryRegistry._();

  final Map<String, QueryHandler> _handlers = <String, QueryHandler>{};

  /// 页面/离屏就绪时登记。同一 pluginId 重复登记时后者覆盖（最小版的取舍）。
  void register(String pluginId, QueryHandler handler) {
    _handlers[pluginId] = handler;
  }

  void unregister(String pluginId) {
    _handlers.remove(pluginId);
  }

  bool has(String pluginId) => _handlers.containsKey(pluginId);

  /// 问某个插件一条数据。永远返回结果对象，**不抛异常**。
  Future<QueryResult> query(
    String pluginId,
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    final handler = _handlers[pluginId];
    if (handler == null) return const QueryResult.unavailable();
    try {
      return await handler(method, params);
    } catch (error) {
      debugPrint('[query] $pluginId.$method 失败：$error');
      return const QueryResult.failed();
    }
  }

  @visibleForTesting
  void debugClear() => _handlers.clear();
}

/// 插件侧的查询处理函数。
typedef QueryHandler = Future<QueryResult> Function(
  String method,
  Map<String, Object?> params,
);
