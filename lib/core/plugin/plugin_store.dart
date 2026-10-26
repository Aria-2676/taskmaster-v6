import 'package:sqflite/sqflite.dart';

import '../data/v6_schema.dart';

/// 一条安装记录。**只描述"装了什么、装在哪"**，不含插件内容。
class InstalledPlugin {
  const InstalledPlugin({
    required this.pluginId,
    required this.version,
    required this.contract,
    required this.installDir,
    required this.installedAt,
    this.enabled = true,
  });

  factory InstalledPlugin.fromRow(Map<String, Object?> row) => InstalledPlugin(
        pluginId: row[InstalledPluginCol.pluginId]! as String,
        version: row[InstalledPluginCol.version]! as String,
        contract: row[InstalledPluginCol.contract]! as int,
        installDir: row[InstalledPluginCol.installDir]! as String,
        installedAt: DateTime.parse(row[InstalledPluginCol.installedAt]! as String),
        enabled: (row[InstalledPluginCol.enabled] as int? ?? 1) != 0,
      );

  final String pluginId;
  final String version;
  final int contract;

  /// 相对插件根目录的安装路径，如 `pomodoro/1.0.0`
  final String installDir;

  final DateTime installedAt;
  final bool enabled;

  Map<String, Object?> toRow() => <String, Object?>{
        InstalledPluginCol.pluginId: pluginId,
        InstalledPluginCol.version: version,
        InstalledPluginCol.contract: contract,
        InstalledPluginCol.installDir: installDir,
        InstalledPluginCol.installedAt: installedAt.toUtc().toIso8601String(),
        InstalledPluginCol.enabled: enabled ? 1 : 0,
      };

  InstalledPlugin copyWith({bool? enabled}) => InstalledPlugin(
        pluginId: pluginId,
        version: version,
        contract: contract,
        installDir: installDir,
        installedAt: installedAt,
        enabled: enabled ?? this.enabled,
      );
}

/// 已安装插件的登记簿。
///
/// 与 `PluginSchemaRegistry` 的分工：那边管**插件私有表**，这边管**装了哪些插件**。
/// 卸载时要一起清理，但顺序必须是"先卸注册（应用层），再删表，最后删这一行"——
/// 反过来的话中途失败会留下"有记录、没文件"的幽灵插件。
class PluginStore {
  PluginStore(this._db);

  final Database _db;

  Future<List<InstalledPlugin>> all() async {
    final rows = await _db.query(V6Table.installedPlugins, orderBy: InstalledPluginCol.pluginId);
    return rows.map(InstalledPlugin.fromRow).toList();
  }

  Future<InstalledPlugin?> find(String pluginId) async {
    final rows = await _db.query(
      V6Table.installedPlugins,
      where: '${InstalledPluginCol.pluginId} = ?',
      whereArgs: <Object?>[pluginId],
      limit: 1,
    );
    return rows.isEmpty ? null : InstalledPlugin.fromRow(rows.first);
  }

  Future<void> upsert(InstalledPlugin plugin) async {
    await _db.insert(
      V6Table.installedPlugins,
      plugin.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> remove(String pluginId) async {
    await _db.delete(
      V6Table.installedPlugins,
      where: '${InstalledPluginCol.pluginId} = ?',
      whereArgs: <Object?>[pluginId],
    );
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    await _db.update(
      V6Table.installedPlugins,
      <String, Object?>{InstalledPluginCol.enabled: enabled ? 1 : 0},
      where: '${InstalledPluginCol.pluginId} = ?',
      whereArgs: <Object?>[pluginId],
    );
  }
}
