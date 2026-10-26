// v6 数据层 —— 插件表的创建与卸载。
//
// 规则（.trae/rules/rule-8 与 docs/main-package.md §4.5）：
//   1. 插件表物理上在**同一个数据库文件**里，表名强制 `plg_<插件id>_<后缀>`
//   2. 每张插件表在自己的 `plg_migrations` 行里记版本，**主包迁移流程不感知插件表**
//   3. 卸载插件 = 按前缀删表 + 删迁移记录；删除前必须校验前缀，防止误删主包表

import 'package:sqflite/sqflite.dart';

import '../plugin/plugin_storage.dart';
import 'v6_schema.dart';

/// 一张插件表的声明。插件安装时由宿主从 manifest 读出并注册。
class PluginTableSpec {
  const PluginTableSpec({
    required this.pluginId,
    required this.suffix,
    required this.columnsSql,
    this.version = 1,
    this.extraSql = const <String>[],
  });

  /// 插件 id，小写字母/数字/连字符
  final String pluginId;

  /// 表名后缀，同一插件内唯一（'records' / 'settings'）
  final String suffix;

  /// 列定义，**不含** `CREATE TABLE` 外壳
  final String columnsSql;

  /// 该表的 schema 版本，用于将来做插件自己的迁移
  final int version;

  /// 建表之后要补的语句（唯一索引、普通索引）。
  ///
  /// 单独拆出来是因为 `CREATE TABLE` 里塞不下索引，而统计型插件
  /// 几乎一定要按日期/状态查 —— 没索引就是全表扫。
  final List<String> extraSql;

  String get tableName => 'plg_${pluginId}_$suffix';

  String get createSql => 'CREATE TABLE IF NOT EXISTS $tableName ($columnsSql)';
}

class PluginSchemaRegistry {
  PluginSchemaRegistry();

  static final PluginSchemaRegistry instance = PluginSchemaRegistry();

  /// 与 `PluginManifest.idPattern` **必须完全一致**。
  ///
  /// 这个 id 会拼成 `plg_<id>_<suffix>` 表名，而 SQLite 的标识符不接受连字符
  /// （`plg_my-plugin_x` 会被解析成减法）。所以只允许小写字母/数字/下划线。
  static final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9_]{1,31}$');

  final Map<String, Map<String, PluginTableSpec>> _byPlugin =
      <String, Map<String, PluginTableSpec>>{};

  /// 注册一张插件表。id 或后缀不合法直接抛 —— 这是安装期的编程错误，必须暴露。
  void register(PluginTableSpec spec) {
    if (!_idPattern.hasMatch(spec.pluginId)) {
      throw ArgumentError.value(spec.pluginId, 'pluginId', '只允许小写字母/数字/下划线，2~32 位');
    }
    if (!_idPattern.hasMatch(spec.suffix)) {
      throw ArgumentError.value(spec.suffix, 'suffix', '只允许小写字母/数字/下划线');
    }
    (_byPlugin[spec.pluginId] ??= <String, PluginTableSpec>{})[spec.suffix] = spec;
  }

  List<PluginTableSpec> specsOf(String pluginId) =>
      (_byPlugin[pluginId] ?? const <String, PluginTableSpec>{}).values.toList();

  List<String> tableNamesOf(String pluginId) =>
      specsOf(pluginId).map((s) => s.tableName).toList();

  /// 建表并登记版本。**只处理已注册的插件**；未注册的插件表不会被创建。
  Future<void> materialize(Database db) async {
    final now = DateTime.now().toIso8601String();
    for (final specs in _byPlugin.values) {
      for (final spec in specs.values) {
        await db.execute(spec.createSql);
        for (final sql in spec.extraSql) {
          await db.execute(sql);
        }
        await db.insert(
          V6Table.pluginMigrations,
          <String, Object?>{
            PluginMigrationCol.pluginId: spec.pluginId,
            PluginMigrationCol.tableName: spec.tableName,
            PluginMigrationCol.version: spec.version,
            PluginMigrationCol.createdAt: now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
  }

  /// 卸载插件：删表 + 删迁移记录。
  ///
  /// 删表清单 = 「当前注册的」∪「`plg_migrations` 里登记过的」，
  /// 两边都过一遍前缀校验，避免旧版本遗留的表删不掉、或误删主包表。
  Future<void> dropPlugin(Database db, String pluginId) async {
    final prefix = 'plg_${pluginId}_';

    final names = <String>{
      ...tableNamesOf(pluginId),
      ...await _recordedTables(db, pluginId),
    };

    for (final name in names) {
      if (!name.startsWith(prefix)) continue; // 前缀守卫：绝不删主包表
      await db.execute('DROP TABLE IF EXISTS $name');
    }

    await db.delete(
      V6Table.pluginMigrations,
      where: '${PluginMigrationCol.pluginId} = ?',
      whereArgs: <Object?>[pluginId],
    );
    _byPlugin.remove(pluginId);
  }

  /// 该插件在库里登记过的表名
  Future<List<String>> _recordedTables(Database db, String pluginId) async {
    final rows = await db.query(
      V6Table.pluginMigrations,
      columns: <String>[PluginMigrationCol.tableName],
      where: '${PluginMigrationCol.pluginId} = ?',
      whereArgs: <Object?>[pluginId],
    );
    return rows
        .map((r) => r[PluginMigrationCol.tableName] as String?)
        .whereType<String>()
        .toList();
  }

  void clear() => _byPlugin.clear();
}

/// 把 manifest 里的 `storage` 声明注册成真实的表。
///
/// 表名、索引名都在这里拼一次，**之后所有地方都从注册表取** ——
/// 绝不允许别处拿插件给的字符串当表名。
extension PluginStorageRegistration on PluginSchemaRegistry {
  void registerStorage(String pluginId, PluginStorageSpec storage) {
    for (final table in storage.tables) {
      final name = 'plg_${pluginId}_${table.name}';
      final columns = <String>[
        // 主键由宿主统一提供，插件不用关心（也不许自己声明 id）
        'id INTEGER PRIMARY KEY AUTOINCREMENT',
        for (final column in table.columns) column.ddl,
      ];

      final extra = <String>[];
      for (var i = 0; i < table.unique.length; i++) {
        final cols = table.unique[i].map((c) => '"$c"').join(', ');
        extra.add('CREATE UNIQUE INDEX IF NOT EXISTS ${name}_u$i ON $name ($cols)');
      }
      for (var i = 0; i < table.indexes.length; i++) {
        final cols = table.indexes[i].map((c) => '"$c"').join(', ');
        extra.add('CREATE INDEX IF NOT EXISTS ${name}_i$i ON $name ($cols)');
      }

      register(PluginTableSpec(
        pluginId: pluginId,
        suffix: table.name,
        columnsSql: columns.join(', '),
        version: storage.version,
        extraSql: extra,
      ));
    }
  }
}
