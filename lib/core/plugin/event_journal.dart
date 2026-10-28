import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/v6_schema.dart';
import '../extension/extension_hook.dart';

/// 一条待投递的事件。
class StoredEvent {
  const StoredEvent({required this.id, required this.hook, required this.payload});

  final int id;
  final HookId hook;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'event': hook.id,
        'payload': payload,
      };
}

/// 事件日志：**没有插件挂载时，事件不许丢**。
///
/// 为什么不做"常驻隐藏 WebView"：每个 WebView 几十 MB，还要处理应用前后台、
/// 被系统杀掉、杀掉之后补不回来 —— 代价远大于收益。改成落库 + 补发：
///
/// - 事件先写这张表（[PluginHookChannel] 实时推一份给在线的插件页面）
/// - 插件挂载后调 `event.pending` 取未确认的，处理完 `event.ack(ids)`
/// - **没 ack 就会再投递**，所以插件必须按 id 幂等（文档里写死这条）
///
/// 表里只放"还没确认"的事件，ack 即删；另有行数上限兜底，防止没人 ack 撑爆。
class EventJournal implements HookListener {
  EventJournal(this._db, {this.maxRows = 200});

  final Database _db;

  /// 最多留多少条。超了删最老的 —— 队列不是档案。
  final int maxRows;

  /// 日志监听器不是某个插件，用一个不会与插件 id 冲突的名字
  @override
  String get pluginId => '@journal';

  @override
  Set<HookId> get hooks => HookId.values.toSet();

  @override
  Future<void> onEvent(HookEvent event) async {
    try {
      await record(event);
    } catch (_) {
      // 落库失败不能反过来影响主流程（写事件是旁路）
    }
  }

  Future<int> record(HookEvent event) async {
    final id = await _db.insert(V6Table.pluginEvents, <String, Object?>{
      PluginEventCol.hook: event.hook.id,
      PluginEventCol.payload: jsonEncode(event.payload),
      PluginEventCol.createdAt: DateTime.now().toUtc().toIso8601String(),
    });
    await prune();
    return id;
  }

  /// 某个插件该收到的事件。按 id 升序（先发生的先投递），只取它声明过的钩子。
  ///
  /// [since] 用于分页：传上一批的最后一条 id，避免一次拉太多。
  ///
  /// [createdAfter] 是 ISO-8601 UTC 时间串，只投递**这个时刻之后**记录的事件。
  /// 用途是"停用期间不攒"：插件停用一周也不该在启用瞬间收到几十条奖励。
  /// 时间是 UTC ISO 串，字典序即时间序，所以直接用字符串比较。
  Future<List<StoredEvent>> pending(
    Set<HookId> hooks, {
    int limit = 50,
    int? since,
    String? createdAfter,
  }) async {
    if (hooks.isEmpty) return const <StoredEvent>[];
    final ids = <String>[for (final hook in hooks) hook.id];
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final conditions = <String>['${PluginEventCol.hook} IN ($placeholders)'];
    final args = <Object?>[...ids];
    if (since != null) {
      conditions.add('${PluginEventCol.id} > ?');
      args.add(since);
    }
    if (createdAfter != null && createdAfter.isNotEmpty) {
      conditions.add('${PluginEventCol.createdAt} >= ?');
      args.add(createdAfter);
    }
    final rows = await _db.query(
      V6Table.pluginEvents,
      where: conditions.join(' AND '),
      whereArgs: args,
      orderBy: '${PluginEventCol.id} ASC',
      limit: limit.clamp(1, 200),
    );

    final known = <String, HookId>{for (final hook in HookId.values) hook.id: hook};
    final result = <StoredEvent>[];
    for (final row in rows) {
      final hook = known[row[PluginEventCol.hook] as String?];
      if (hook == null) continue; // 宿主已经不认识的钩子，直接跳过
      result.add(StoredEvent(
        id: row[PluginEventCol.id]! as int,
        hook: hook,
        payload: _decode(row[PluginEventCol.payload] as String?),
      ));
    }
    return result;
  }

  /// 确认收到。**ack 之后才删** —— 先删再投，插件一崩就永久丢事件。
  Future<int> ack(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    return _db.delete(
      V6Table.pluginEvents,
      where: '${PluginEventCol.id} IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM ${V6Table.pluginEvents}');
    return rows.first['n']! as int;
  }

  /// 超过上限就删最老的。没人 ack 的坏插件不该把库撑大。
  Future<int> prune() async {
    final total = await count();
    if (total <= maxRows) return 0;
    // 先算出要保留的最小 id，再删比它小的 —— 比 NOT IN 子查询省事且好懂
    final rows = await _db.rawQuery(
      'SELECT ${PluginEventCol.id} AS id FROM ${V6Table.pluginEvents} '
      'ORDER BY ${PluginEventCol.id} DESC LIMIT 1 OFFSET ?',
      <Object?>[maxRows - 1],
    );
    if (rows.isEmpty) return 0;
    final cutoff = rows.first['id']! as int;
    return _db.delete(
      V6Table.pluginEvents,
      where: '${PluginEventCol.id} < ?',
      whereArgs: <Object?>[cutoff],
    );
  }

  static Map<String, Object?> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{};
    } catch (_) {
      return const <String, Object?>{};
    }
  }
}
