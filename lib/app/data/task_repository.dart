import 'package:sqflite/sqflite.dart';

import '../../core/data/v6_schema.dart';
import '../models/recycled_task.dart';
import '../models/task.dart';

/// v6 的任务仓储。**唯一**直接写 `tasks` / `task_tags` 表的地方。
///
/// 刻意只做四件事：按日取、改完成态、进回收站、批量取标签。
/// 不做货币、不做统计——那些要么是插件的活，要么读别的表。
class TaskRepository {
  TaskRepository(this._db);

  final Database _db;

  /// 优先级排序：红 > 橙 > 黄 > 蓝 > 白。放 SQL 里做，避免全量取回内存再排。
  static const String _priorityRank = '''
    CASE t.${TaskCol.priority}
      WHEN 'red' THEN 1
      WHEN 'orange' THEN 2
      WHEN 'yellow' THEN 3
      WHEN 'blue' THEN 4
      ELSE 5
    END''';

  /// 取某一天的任务。未完成的排前面，其次按优先级，再按创建时间。
  Future<List<Task>> tasksOn(DateTime day) async {
    final rows = await _db.rawQuery('''
      SELECT t.*, (
        SELECT GROUP_CONCAT(${TaskTagCol.tagId})
        FROM ${V6Table.taskTags} tt
        WHERE tt.${TaskTagCol.taskId} = t.${TaskCol.id}
      ) AS tag_ids
      FROM ${V6Table.tasks} t
      WHERE t.${TaskCol.cplTime} = ?
      ORDER BY t.${TaskCol.isOk} ASC, $_priorityRank, t.${TaskCol.createdAt} ASC
    ''', <Object?>[TaskDate.dayKey(day)]);
    return _hydrate(rows);
  }

  /// 取一段日期（含首尾）的任务数，供日历标记/统计类插件使用。
  Future<Map<DateTime, int>> dailyCounts(DateTime from, DateTime to) async {
    final rows = await _db.rawQuery('''
      SELECT ${TaskCol.cplTime} AS d, COUNT(*) AS n
      FROM ${V6Table.tasks}
      WHERE ${TaskCol.cplTime} >= ? AND ${TaskCol.cplTime} <= ?
      GROUP BY ${TaskCol.cplTime}
    ''', <Object?>[TaskDate.dayKey(from), TaskDate.dayKey(to)]);
    return <DateTime, int>{
      for (final r in rows) TaskDate.parseDay(r['d']! as String): r['n']! as int,
    };
  }

  /// 取一段日期（含首尾）的任务，供插件的数据 API 使用。
  /// **必须带 limit**：不允许插件一次拉全量。
  Future<List<Task>> tasksBetween(DateTime from, DateTime to, {int limit = 200}) async {
    final rows = await _db.rawQuery('''
      SELECT t.*, (
        SELECT GROUP_CONCAT(${TaskTagCol.tagId})
        FROM ${V6Table.taskTags} tt
        WHERE tt.${TaskTagCol.taskId} = t.${TaskCol.id}
      ) AS tag_ids
      FROM ${V6Table.tasks} t
      WHERE t.${TaskCol.cplTime} >= ? AND t.${TaskCol.cplTime} <= ?
      ORDER BY t.${TaskCol.cplTime} ASC, $_priorityRank
      LIMIT ?
    ''', <Object?>[TaskDate.dayKey(from), TaskDate.dayKey(to), limit]);
    return _hydrate(rows);
  }

  /// 早于 [before] 且**未完成**的任务（逾期）。
  ///
  /// 逾期任务不该消失：用户不会记得回翻日期，漏掉的会一直漏。
  /// 只取未完成的 —— 昨天做完的不算逾期，那是历史。
  /// 排序按日期**倒序**：昨天的比上个月的更相关。
  Future<List<Task>> overdueBefore(DateTime before, {int limit = 100}) async {
    final rows = await _db.rawQuery('''
      SELECT t.*, (
        SELECT GROUP_CONCAT(${TaskTagCol.tagId})
        FROM ${V6Table.taskTags} tt
        WHERE tt.${TaskTagCol.taskId} = t.${TaskCol.id}
      ) AS tag_ids
      FROM ${V6Table.tasks} t
      WHERE t.${TaskCol.cplTime} < ? AND t.${TaskCol.isOk} = 0
      ORDER BY t.${TaskCol.cplTime} DESC, $_priorityRank
      LIMIT ?
    ''', <Object?>[TaskDate.dayKey(before), limit]);
    return _hydrate(rows);
  }

  Future<List<Tag>> allTags() async {    final rows = await _db.query(V6Table.tags, orderBy: TagCol.id);
    return rows
        .map((r) => Tag(
              id: r[TagCol.id]! as int,
              name: r[TagCol.name] as String? ?? '',
              color: r[TagCol.color] as String? ?? '#2196F3',
            ))
        .toList();
  }

  Future<int> insert({
    required String title,
    required DateTime day,
    String? description,
    String priority = 'white',
    int? estimatedMinutes,
    List<int> tagIds = const <int>[],
  }) async {
    return _db.transaction<int>((txn) async {
      final now = DateTime.now();
      final id = await txn.insert(V6Table.tasks, <String, Object?>{
        TaskCol.title: title,
        TaskCol.description: description,
        TaskCol.cplTime: TaskDate.dayKey(day),
        TaskCol.priority: priority,
        TaskCol.isOk: 0,
        TaskCol.isWord: 0,
        TaskCol.recurrence: 'none',
        TaskCol.estimatedMinutes: estimatedMinutes,
        TaskCol.createdAt: TaskDate.timeKey(now),
      });
      for (final tagId in tagIds) {
        await txn.insert(
          V6Table.taskTags,
          <String, Object?>{TaskTagCol.taskId: id, TaskTagCol.tagId: tagId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      return id;
    });
  }

  /// 全量更新一个任务，并**替换**它的标签关联。
  ///
  /// 标签用"先删后插"而不是做差集：任务上的标签通常只有几个，
  /// 差集要读一次、比一次、再算增删，代码更多而收益为零。
  Future<void> update(
    int id, {
    required String title,
    String? description,
    required DateTime day,
    required String priority,
    int? estimatedMinutes,
    List<int> tagIds = const <int>[],
  }) async {
    await _db.transaction((txn) async {
      await txn.update(
        V6Table.tasks,
        <String, Object?>{
          TaskCol.title: title,
          TaskCol.description: description,
          TaskCol.cplTime: TaskDate.dayKey(day),
          TaskCol.priority: priority,
          TaskCol.estimatedMinutes: estimatedMinutes,
        },
        where: '${TaskCol.id} = ?',
        whereArgs: <Object?>[id],
      );

      await txn.delete(
        V6Table.taskTags,
        where: '${TaskTagCol.taskId} = ?',
        whereArgs: <Object?>[id],
      );
      for (final tagId in tagIds) {
        await txn.insert(
          V6Table.taskTags,
          <String, Object?>{TaskTagCol.taskId: id, TaskTagCol.tagId: tagId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<void> setDone(int id, bool done) async {
    await _db.update(
      V6Table.tasks,
      <String, Object?>{
        TaskCol.isOk: done ? 1 : 0,
        TaskCol.completedAt: done ? TaskDate.timeKey(DateTime.now()) : null,
      },
      where: '${TaskCol.id} = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 部分更新。**给插件写接口用**：插件只交它想改的那几项，
  /// 没提到的列一律不动（和 [update] 的"全量覆盖"是两件事）。
  ///
  /// [fields] 的 key 必须来自 [TaskCol] 常量，值已经过校验 —— 这里不猜类型，
  /// 拼 SQL 用的是这些 key，所以上层绝不能直接塞外部字符串进来。
  /// [tagIds] 为 null 表示"不动标签"，空列表表示"清空标签"。
  ///
  /// 返回 false 表示没有这条任务（插件拿了个过期的 id）。
  Future<bool> patch(
    int id,
    Map<String, Object?> fields, {
    List<int>? tagIds,
  }) async {
    if (fields.isEmpty && tagIds == null) return false;
    return _db.transaction<bool>((txn) async {
      final exists = await txn.query(
        V6Table.tasks,
        columns: <String>[TaskCol.id],
        where: '${TaskCol.id} = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (exists.isEmpty) return false;

      if (fields.isNotEmpty) {
        await txn.update(
          V6Table.tasks,
          fields,
          where: '${TaskCol.id} = ?',
          whereArgs: <Object?>[id],
        );
      }
      if (tagIds != null) {
        await txn.delete(
          V6Table.taskTags,
          where: '${TaskTagCol.taskId} = ?',
          whereArgs: <Object?>[id],
        );
        for (final tagId in tagIds) {
          await txn.insert(
            V6Table.taskTags,
            <String, Object?>{TaskTagCol.taskId: id, TaskTagCol.tagId: tagId},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
      return true;
    });
  }

  /// 某条任务是否存在（插件的 update 前先判一下，好回 not_found 而不是静默失败）
  Future<bool> exists(int id) async {
    final rows = await _db.query(
      V6Table.tasks,
      columns: <String>[TaskCol.id],
      where: '${TaskCol.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 单条任务（带标签）。钩子发事件时要用它的完整信息，
  /// 否则订阅方（货币插件）拿不到估时，算不出该给多少。
  Future<Task?> findById(int id) async {
    final rows = await _db.rawQuery('''
      SELECT t.*, (
        SELECT GROUP_CONCAT(${TaskTagCol.tagId})
        FROM ${V6Table.taskTags} tt
        WHERE tt.${TaskTagCol.taskId} = t.${TaskCol.id}
      ) AS tag_ids
      FROM ${V6Table.tasks} t
      WHERE t.${TaskCol.id} = ?
      LIMIT 1
    ''', <Object?>[id]);
    final list = await _hydrate(rows);
    return list.isEmpty ? null : list.first;
  }
  /// 删除任务。
  ///
  /// [toRecycle] 为 true 时整行拷进 `recycled_tasks`（可恢复），
  /// 为 false 时**直接物理删除**（`task_tags` 靠外键级联清掉）。
  /// 默认值故意不设成"进回收站"——由调用方按用户开关显式传入，
  /// 免得哪天忘了传就悄悄留下垃圾。
  Future<void> delete(int id, {required bool toRecycle}) async {
    if (!toRecycle) {
      await _db.delete(
        V6Table.tasks,
        where: '${TaskCol.id} = ?',
        whereArgs: <Object?>[id],
      );
      return;
    }
    await moveToRecycle(id);
  }

  /// 进回收站：整行拷到 `recycled_tasks`，再删原行（`task_tags` 靠外键级联清理）。
  Future<void> moveToRecycle(int id) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        V6Table.tasks,
        where: '${TaskCol.id} = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) return;

      // 先把标签 id 记下来：删任务时 `task_tags` 会被外键级联清掉，
      // 不在这里存快照，恢复出来的任务就永远是"裸"的。
      final tagRows = await txn.query(
        V6Table.taskTags,
        columns: <String>[TaskTagCol.tagId],
        where: '${TaskTagCol.taskId} = ?',
        whereArgs: <Object?>[id],
      );
      final tagIds = tagRows
          .map((r) => r[TaskTagCol.tagId])
          .whereType<int>()
          .toList()
        ..sort();

      final row = Map<String, Object?>.of(rows.first)
        ..remove(TaskCol.id)
        ..[RecycledTaskCol.taskId] = id
        ..[RecycledTaskCol.deletedAt] = TaskDate.timeKey(DateTime.now())
        ..[RecycledTaskCol.tagIds] = tagIds.isEmpty ? null : tagIds.join(',');
      await txn.insert(V6Table.recycledTasks, row);
      await txn.delete(V6Table.tasks, where: '${TaskCol.id} = ?', whereArgs: <Object?>[id]);
    });
  }

  /// 回收站列表，最近删除的在前
  Future<List<RecycledTask>> recycledTasks({int limit = 200}) async {
    final rows = await _db.query(
      V6Table.recycledTasks,
      orderBy: '${RecycledTaskCol.deletedAt} DESC',
      limit: limit,
    );
    return rows.map(RecycledTask.fromRow).toList();
  }

  Future<int> recycledCount() async {
    final rows =
        await _db.rawQuery('SELECT COUNT(*) AS n FROM ${V6Table.recycledTasks}');
    return rows.first['n']! as int;
  }

  /// 从回收站恢复：拷回 `tasks`（**拿新 id**，原 id 已被自增序列让给别人），
  /// 成功后再删回收站那行。
  ///
  /// 标签会一起恢复：删除时把 tag id 存进了 `recycled_tasks.tag_ids`。
  /// 唯一会丢的情况是那个标签在这期间被删掉了 —— 外键不允许指向不存在的标签，
  /// 所以只能跳过它，而不是让整条恢复失败。
  Future<void> restoreFromRecycle(int recycledId) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        V6Table.recycledTasks,
        where: '${RecycledTaskCol.id} = ?',
        whereArgs: <Object?>[recycledId],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final snapshot = rows.first;
      final restored = Map<String, Object?>.of(snapshot)
        ..remove(RecycledTaskCol.id)
        ..remove(RecycledTaskCol.taskId)
        ..remove(RecycledTaskCol.deletedAt)
        ..remove(RecycledTaskCol.tagIds);

      final newTaskId = await txn.insert(V6Table.tasks, restored);

      // 重建标签关联。**只重建仍然存在的标签**：标签可能在这期间被删了，
      // 直接插会让外键拒绝整条事务，用户看到的是"恢复失败"。
      final raw = snapshot[RecycledTaskCol.tagIds] as String?;
      if (raw != null && raw.isNotEmpty) {
        for (final tagId in raw.split(',').map(int.tryParse).whereType<int>()) {
          final exists = await txn.query(
            V6Table.tags,
            columns: <String>[TagCol.id],
            where: '${TagCol.id} = ?',
            whereArgs: <Object?>[tagId],
            limit: 1,
          );
          if (exists.isEmpty) continue;
          await txn.insert(
            V6Table.taskTags,
            <String, Object?>{TaskTagCol.taskId: newTaskId, TaskTagCol.tagId: tagId},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      await txn.delete(
        V6Table.recycledTasks,
        where: '${RecycledTaskCol.id} = ?',
        whereArgs: <Object?>[recycledId],
      );
    });
  }

  /// 永久删除回收站里的单条
  Future<void> purgeRecycled(int recycledId) async {
    await _db.delete(
      V6Table.recycledTasks,
      where: '${RecycledTaskCol.id} = ?',
      whereArgs: <Object?>[recycledId],
    );
  }

  /// 清空回收站
  Future<void> purgeAllRecycled() async {
    await _db.delete(V6Table.recycledTasks);
  }

  /// 统计超过 [age] 的回收站条目数。
  /// 用于"把保留时长改短"之前的确认 —— 得先知道会删掉几条，
  /// 否则确认框只能说一句空话。
  Future<int> countRecycleOlderThan(Duration age) async {
    final cutoff = TaskDate.timeKey(DateTime.now().subtract(age));
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${V6Table.recycledTasks} '
      'WHERE ${RecycledTaskCol.deletedAt} < ?',
      <Object?>[cutoff],
    );
    return rows.first['n']! as int;
  }

  /// 清理超过 [age] 的回收站记录，返回删掉的行数。
  ///
  /// 没有后台服务：在每次打开 app 时扫一遍即可 —— 这是本地离线应用，
  /// 用户不开 app 的时间段里"过期数据还留着"没有任何影响。
  Future<int> purgeRecycleOlderThan(Duration age) async {
    final cutoff = TaskDate.timeKey(DateTime.now().subtract(age));
    return _db.delete(
      V6Table.recycledTasks,
      where: '${RecycledTaskCol.deletedAt} < ?',
      whereArgs: <Object?>[cutoff],
    );
  }

  Future<int> countTasks() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM ${V6Table.tasks}');
    return rows.first['n']! as int;
  }

  Future<void> insertTag(Tag tag) async {
    await _db.insert(
      V6Table.tags,
      <String, Object?>{
        TagCol.name: tag.name,
        TagCol.color: tag.color,
        TagCol.createdAt: TaskDate.timeKey(DateTime.now()),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> renameTag(int id, String name) async {
    await _db.update(
      V6Table.tags,
      <String, Object?>{TagCol.name: name},
      where: '${TagCol.id} = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setTagColor(int id, String color) async {
    await _db.update(
      V6Table.tags,
      <String, Object?>{TagCol.color: color},
      where: '${TagCol.id} = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 删标签。`task_tags` 靠外键 CASCADE 自动清掉，**任务本身不受影响**。
  Future<void> deleteTag(int id) async {
    await _db.delete(V6Table.tags, where: '${TagCol.id} = ?', whereArgs: <Object?>[id]);
  }

  /// 每个标签被多少个任务使用（标签管理页显示"3 个任务"用）。
  ///
  /// 只统计 `tasks` 里的：回收站里的任务不算"正在用"，
  /// 否则删标签时那句"N 个任务在用"会把人吓住。
  Future<Map<int, int>> tagUsage() async {
    final rows = await _db.rawQuery('''
      SELECT tt.${TaskTagCol.tagId} AS id, COUNT(*) AS n
      FROM ${V6Table.taskTags} tt
      JOIN ${V6Table.tasks} t ON t.${TaskCol.id} = tt.${TaskTagCol.taskId}
      GROUP BY tt.${TaskTagCol.tagId}
    ''');
    return <int, int>{
      for (final r in rows) r['id']! as int: r['n']! as int,
    };
  }

  /// 批量取标签，避免每个任务都查一次（N+1）。
  Future<List<Task>> _hydrate(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const <Task>[];
    final tags = await allTags();
    final byId = <int, Tag>{for (final t in tags) t.id: t};

    return rows.map((row) {
      final raw = row['tag_ids'] as String?;
      final ids = raw == null
          ? const <int>[]
          : raw.split(',').map(int.tryParse).whereType<int>().toList();
      return Task.fromRow(
        row,
        tags: ids.map((i) => byId[i]).whereType<Tag>().toList(),
      );
    }).toList();
  }
}
