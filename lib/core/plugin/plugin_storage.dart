/// 插件自带数据的存储契约（**B 方案：插件私有表**）。
///
/// 为什么不用"通用集合表 + JSON"：统计型插件要按维度聚合（`GROUP BY day`、
/// `SUM(minutes)`），JSON 塞在一列里只能全量拉回内存算，数据一多就废。
/// 让插件声明真实列，统计才走得了索引和 SQL 聚合。
///
/// 安全边界（三条，缺一不可）：
///   1. 表名强制 `plg_<id>_<name>`，**插件无法指向主包表**
///   2. 列定义只能用 [PluginColumn] 的白名单类型，不接受裸 SQL 片段
///   3. 查询走 [PluginDataStore] 的构造器，标识符必须声明过、值一律参数化
///      —— **永远不执行插件传来的 SQL 字符串**
library;

import 'package:sqflite/sqflite.dart';



/// 列类型白名单。故意不含 blob：插件没有理由往主库里塞二进制。
enum PluginColumnType {
  text('text'),
  integer('integer'),
  real('real');

  const PluginColumnType(this.sql);

  final String sql;

  static PluginColumnType? parse(Object? raw) {
    for (final type in values) {
      if (type.sql == raw) return type;
    }
    return null;
  }
}

final RegExp _identPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// 一列的声明
class PluginColumn {
  const PluginColumn({
    required this.name,
    required this.type,
    this.notNull = false,
    this.defaultValue,
  });

  factory PluginColumn.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final type = PluginColumnType.parse(json['type']);
    if (name is! String || !_identPattern.hasMatch(name)) {
      throw const PluginStorageException('列名非法（小写字母/数字/下划线，≤32 位）');
    }
    if (name == 'id') {
      // id 由宿主加，插件自己再声明会撞名
      throw const PluginStorageException('列名 id 由宿主提供，插件不要声明');
    }
    if (type == null) {
      throw PluginStorageException('列 $name 的类型非法（只支持 text / integer / real）');
    }
    final defaultValue = json['default'];
    if (defaultValue != null && defaultValue is! String && defaultValue is! num) {
      throw PluginStorageException('列 $name 的默认值只能是字符串或数字');
    }
    return PluginColumn(
      name: name,
      type: type,
      notNull: json['notNull'] == true,
      defaultValue: defaultValue,
    );
  }

  final String name;
  final PluginColumnType type;
  final bool notNull;
  final Object? defaultValue;

  String get ddl {
    final buffer = StringBuffer('"$name" ${type.sql}');
    if (notNull) buffer.write(' NOT NULL');
    if (defaultValue != null) {
      buffer.write(defaultValue is num
          ? ' DEFAULT $defaultValue'
          : " DEFAULT '${defaultValue.toString().replaceAll("'", "''")}'");
    }
    return buffer.toString();
  }
}

/// 一张表的声明
class PluginTableDecl {
  const PluginTableDecl({
    required this.name,
    required this.columns,
    this.unique = const <List<String>>[],
    this.indexes = const <List<String>>[],
  });

  factory PluginTableDecl.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    if (name is! String || !_identPattern.hasMatch(name)) {
      throw const PluginStorageException('表名非法（小写字母/数字/下划线，≤32 位）');
    }

    final rawColumns = json['columns'];
    if (rawColumns is! List || rawColumns.isEmpty) {
      throw PluginStorageException('表 $name 至少要声明一列');
    }
    if (rawColumns.length > 24) {
      throw PluginStorageException('表 $name 列太多（上限 24）');
    }
    final columns = <PluginColumn>[
      for (final item in rawColumns)
        if (item is Map)
          PluginColumn.fromJson(Map<String, Object?>.from(item))
        else
          throw PluginStorageException('表 $name 的列声明必须是对象'),
    ];
    final seen = <String>{};
    for (final column in columns) {
      if (!seen.add(column.name)) {
        throw PluginStorageException('表 $name 有重复列：${column.name}');
      }
    }

    return PluginTableDecl(
      name: name,
      columns: columns,
      unique: _parseColumnGroups(json['unique'], name),
      indexes: _parseColumnGroups(json['indexes'], name),
    );
  }

  final String name;
  final List<PluginColumn> columns;

  /// 唯一约束（列组合）。写成 `[["day"]]` 这种数组的数组，
  /// 单列也包一层 —— 统一形状，省得解析时判两种。
  final List<List<String>> unique;

  /// 普通索引。统计插件几乎一定要按日期/状态查，没索引会全表扫。
  final List<List<String>> indexes;

  Iterable<String> get columnNames => columns.map((c) => c.name);

  String get fullName => name;

  static List<List<String>> _parseColumnGroups(Object? raw, String table) {
    if (raw == null) return const <List<String>>[];
    if (raw is! List) throw PluginStorageException('表 $table 的 unique/indexes 必须是数组');
    return <List<String>>[
      for (final group in raw)
        if (group is List)
          <String>[
            for (final column in group)
              if (column is String && _identPattern.hasMatch(column))
                column
              else
                throw PluginStorageException('表 $table 的列名非法：$column'),
          ]
        else
          throw PluginStorageException('表 $table 的 unique/indexes 里每项必须是列名数组'),
    ];
  }
}

/// 整个 storage 段
class PluginStorageSpec {
  const PluginStorageSpec({
    required this.version,
    required this.tables,
  });

  factory PluginStorageSpec.fromJson(Object? raw) {
    if (raw == null) return const PluginStorageSpec(version: 1, tables: <PluginTableDecl>[]);
    if (raw is! Map) throw const PluginStorageException('storage 必须是对象');
    final json = Map<String, Object?>.from(raw);
    final version = json['version'];
    final rawTables = json['tables'];

    if (version != null && version is! int) {
      throw const PluginStorageException('storage.version 必须是整数');
    }
    if (rawTables != null && rawTables is! List) {
      throw const PluginStorageException('storage.tables 必须是数组');
    }
    final tables = <PluginTableDecl>[
      for (final item in (rawTables as List?) ?? const <Object?>[])
        if (item is Map)
          PluginTableDecl.fromJson(Map<String, Object?>.from(item))
        else
          throw const PluginStorageException('storage.tables 里每项必须是对象'),
    ];
    if (tables.length > 8) {
      throw const PluginStorageException('一个插件最多 8 张表');
    }
    final names = <String>{};
    for (final table in tables) {
      if (!names.add(table.name)) {
        throw PluginStorageException('重复的表声明：${table.name}');
      }
    }
    return PluginStorageSpec(version: (version as int?) ?? 1, tables: tables);
  }

  final int version;
  final List<PluginTableDecl> tables;

  bool get isEmpty => tables.isEmpty;

  PluginTableDecl? table(String name) {
    for (final table in tables) {
      if (table.name == name) return table;
    }
    return null;
  }
}

class PluginStorageException implements Exception {
  const PluginStorageException(this.message);

  final String message;

  @override
  String toString() => 'PluginStorageException: $message';
}

/// 插件数据的受限读写口。
///
/// **所有标识符都来自插件 manifest 的声明**，且在建 SQL 前再校验一次；
/// 值一律走 `?` 参数。也就是说，插件即使想注入也只能往"自己声明的列"里写。
class PluginDataStore {
  PluginDataStore({
    required this.db,
    required this.pluginId,
    required PluginStorageSpec spec,
  }) : _spec = spec;

  final Database db;
  final String pluginId;
  final PluginStorageSpec _spec;

  static const Set<String> _ops = <String>{
    '=', '!=', '<', '<=', '>', '>=', 'like', 'in', 'isNull', 'notNull',
  };

  static const Set<String> _aggregates = <String>{'count', 'sum', 'avg', 'min', 'max'};

  static const int _maxLimit = 500;

  String tableName(PluginTableDecl table) => 'plg_${pluginId}_${table.name}';

  /// 按声明取表；没声明过就拒绝 —— 这是"插件只能碰自己的表"的唯一入口
  PluginTableDecl _requireTable(Object? raw) {
    if (raw is! String) throw const PluginDataException('bad_params', 'table 必须是字符串');
    final table = _spec.table(raw);
    if (table == null) {
      throw PluginDataException('bad_params', '没有声明过这张表：$raw');
    }
    return table;
  }

  void _requireColumn(PluginTableDecl table, String column) {
    if (column == 'id') return; // 宿主加的
    if (!table.columnNames.contains(column)) {
      throw PluginDataException('bad_params', '表 ${table.name} 没有列 $column');
    }
  }

  /// 组装 where。返回 (sql, args)
  (String, List<Object?>) _where(PluginTableDecl table, Object? raw) {
    if (raw == null) return ('', <Object?>[]);
    if (raw is! List) throw const PluginDataException('bad_params', 'where 必须是数组');
    if (raw.length > 20) throw const PluginDataException('bad_params', 'where 条件太多（上限 20）');

    final clauses = <String>[];
    final args = <Object?>[];
    for (final item in raw) {
      if (item is! Map) throw const PluginDataException('bad_params', 'where 每项必须是对象');
      final json = Map<String, Object?>.from(item);
      final column = json['column'];
      final op = json['op'] ?? '=';
      if (column is! String) throw const PluginDataException('bad_params', 'where.column 必须是字符串');
      _requireColumn(table, column);
      if (op is! String || !_ops.contains(op)) {
        throw PluginDataException('bad_params', '不支持的比较符：$op');
      }
      switch (op) {
        case 'isNull':
          clauses.add('"$column" IS NULL');
        case 'notNull':
          clauses.add('"$column" IS NOT NULL');
        case 'in':
          final values = json['value'];
          if (values is! List || values.isEmpty) {
            throw const PluginDataException('bad_params', 'in 的 value 必须是非空数组');
          }
          if (values.length > 100) {
            throw const PluginDataException('bad_params', 'in 的取值太多（上限 100）');
          }
          clauses.add('"$column" IN (${List<String>.filled(values.length, '?').join(',')})');
          args.addAll(values);
        default:
          if (!json.containsKey('value')) {
            throw PluginDataException('bad_params', '$op 需要 value');
          }
          clauses.add('"$column" $op ?');
          args.add(json['value']);
      }
    }
    if (clauses.isEmpty) return ('', <Object?>[]);
    return ('WHERE ${clauses.join(' AND ')}', args);
  }

  Future<int> insert(String table, Map<String, Object?> values) async {
    final decl = _requireTable(table);
    if (values.isEmpty) throw const PluginDataException('bad_params', 'values 不能为空');
    for (final key in values.keys) {
      _requireColumn(decl, key);
    }
    return db.insert(tableName(decl), values);
  }

  Future<int> update(String table, Map<String, Object?> values, Object? where) async {
    final decl = _requireTable(table);
    if (values.isEmpty) throw const PluginDataException('bad_params', 'values 不能为空');
    for (final key in values.keys) {
      _requireColumn(decl, key);
    }
    final (whereSql, args) = _where(decl, where);
    if (whereSql.isEmpty) {
      // 不带条件的 update 等于清库，插件不该有这种能力
      throw const PluginDataException('bad_params', 'update 必须带 where');
    }
    return db.update(tableName(decl), values, where: whereSql.replaceFirst('WHERE ', ''), whereArgs: args);
  }

  Future<int> delete(String table, Object? where) async {
    final decl = _requireTable(table);
    final (whereSql, args) = _where(decl, where);
    if (whereSql.isEmpty) throw const PluginDataException('bad_params', 'delete 必须带 where');
    return db.delete(tableName(decl), where: whereSql.replaceFirst('WHERE ', ''), whereArgs: args);
  }

  Future<List<Map<String, Object?>>> select(
    String table, {
    List<String>? columns,
    Object? where,
    List<Map<String, Object?>>? orderBy,
    int? limit,
    int? offset,
  }) async {
    final decl = _requireTable(table);
    final selected = <String>[];
    if (columns != null) {
      if (columns.length > 24) throw const PluginDataException('bad_params', 'columns 太多');
      for (final column in columns) {
        _requireColumn(decl, column);
        selected.add('"$column"');
      }
    }

    final (whereSql, args) = _where(decl, where);
    final order = <String>[];
    for (final item in orderBy ?? const <Map<String, Object?>>[]) {
      final column = item['column'];
      if (column is! String) throw const PluginDataException('bad_params', 'orderBy.column 必须是字符串');
      _requireColumn(decl, column);
      order.add('"$column" ${item['desc'] == true ? 'DESC' : 'ASC'}');
    }

    final buffer = StringBuffer('SELECT ${selected.isEmpty ? '*' : selected.join(',')} '
        'FROM ${tableName(decl)}');
    if (whereSql.isNotEmpty) buffer.write(' $whereSql');
    if (order.isNotEmpty) buffer.write(' ORDER BY ${order.join(',')}');
    buffer.write(' LIMIT ?');
    args.add((limit ?? 100).clamp(1, _maxLimit));
    if (offset != null && offset > 0) {
      buffer.write(' OFFSET ?');
      args.add(offset);
    }
    return db.rawQuery(buffer.toString(), args);
  }

  /// 聚合。统计插件的核心：`GROUP BY` + `count/sum/avg/min/max`。
  Future<List<Map<String, Object?>>> aggregate(
    String table, {
    List<String>? groupBy,
    required List<Map<String, Object?>> metrics,
    Object? where,
  }) async {
    final decl = _requireTable(table);
    if (metrics.isEmpty) throw const PluginDataException('bad_params', 'metrics 不能为空');
    if (metrics.length > 8) throw const PluginDataException('bad_params', 'metrics 太多（上限 8）');

    final groups = <String>[];
    for (final column in groupBy ?? const <String>[]) {
      _requireColumn(decl, column);
      groups.add('"$column"');
    }

    final selects = <String>[...groups];
    for (final metric in metrics) {
      final fn = metric['fn'];
      final column = metric['column'];
      final alias = metric['as'];
      if (fn is! String || !_aggregates.contains(fn)) {
        throw PluginDataException('bad_params', '不支持的聚合函数：$fn');
      }
      if (alias is! String || alias.isEmpty || alias.length > 32) {
        throw const PluginDataException('bad_params', 'metrics.as 必须是 1~32 字的别名');
      }
      if (fn == 'count' && column == '*') {
        selects.add('COUNT(*) AS "$alias"');
        continue;
      }
      if (column is! String) {
        throw const PluginDataException('bad_params', 'metrics.column 必须是字符串');
      }
      _requireColumn(decl, column);
      selects.add('${fn.toUpperCase()}("$column") AS "$alias"');
    }

    final (whereSql, args) = _where(decl, where);
    final buffer = StringBuffer('SELECT ${selects.join(',')} FROM ${tableName(decl)}');
    if (whereSql.isNotEmpty) buffer.write(' $whereSql');
    if (groups.isNotEmpty) buffer.write(' GROUP BY ${groups.join(',')}');
    return db.rawQuery(buffer.toString(), args);
  }
}

/// 数据层的错误。和 bridge 的错误码对齐，调用方只需要接一种。
class PluginDataException implements Exception {
  const PluginDataException(this.code, this.message);

  final String code;
  final String message;
}
