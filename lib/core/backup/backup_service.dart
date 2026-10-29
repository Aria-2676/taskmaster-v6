import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqflite/sqflite.dart';

import '../data/v6_schema.dart';

/// 备份文件的格式常量与清单。
///
/// 一个备份 = 一个 zip，里面两个 json：
///   manifest.json  小、可读：格式版本 / 创建时间 / App 版本 / 各段条数
///   data.json      全量数据
///
/// 拆开是为了**列表页不必解全量**：用户有 20 份备份时，只看摘要就够了。
class BackupFormat {
  const BackupFormat._();

  static const int currentVersion = 1;

  /// 粗校验：不是本产品的文件就别往下解析了
  static const String formatId = 'taskmaster-v6-backup';

  static const String manifestEntry = 'manifest.json';
  static const String dataEntry = 'data.json';

  /// 备份文件在手机上的扩展名。用 .zip：分享出去任何客户端都认得
  static const String fileExtension = 'zip';
}

class BackupManifest {
  const BackupManifest({
    required this.createdAt,
    required this.appVersion,
    required this.counts,
    required this.included,
    this.formatVersion = BackupFormat.currentVersion,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final id = json['format'];
    if (id != BackupFormat.formatId) {
      throw BackupException('这不是任务管家的备份文件');
    }
    final version = json['formatVersion'];
    if (version is! int) throw BackupException('备份文件缺少 formatVersion');
    if (version > BackupFormat.currentVersion) {
      throw BackupException('备份是更新版本导出的（formatVersion=$version），请先升级 App');
    }
    return BackupManifest(
      formatVersion: version,
      createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
      appVersion: '${json['appVersion'] ?? '未知'}',
      counts: <String, int>{
        for (final entry in (json['counts'] as Map? ?? const <String, Object?>{}).entries)
          '${entry.key}': entry.value is int ? entry.value! as int : 0,
      },
      included: <String>[
        for (final item in (json['included'] as List? ?? const <Object?>[])) '$item',
      ],
    );
  }

  final int formatVersion;
  final DateTime createdAt;
  final String appVersion;

  /// 各段条数，例如 {'tasks': 128, 'tags': 6, 'plugin:energy_currency': 40}
  final Map<String, int> counts;

  /// 实际包含的段，列表页展示用
  final List<String> included;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': BackupFormat.formatId,
        'formatVersion': formatVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'appVersion': appVersion,
        'counts': counts,
        'included': included,
      };

  String get summary {
    final parts = <String>[];
    if (counts['tasks'] != null) parts.add('任务 ${counts['tasks']}');
    if (counts['tags'] != null) parts.add('标签 ${counts['tags']}');
    final plugins = counts.entries.where((e) => e.key.startsWith('plugin:')).toList();
    if (plugins.isNotEmpty) parts.add('插件 ${plugins.length}');
    return parts.isEmpty ? '空备份' : parts.join(' · ');
  }
}

/// 备份里某个插件那一段
class PluginBackup {
  const PluginBackup({this.version, required this.tables, required this.kv});

  factory PluginBackup.fromJson(Map<String, Object?> json) => PluginBackup(
        version: json['version'] as String?,
        tables: <String, List<Map<String, Object?>>>{
          for (final entry in (json['tables'] as Map? ?? const <String, Object?>{}).entries)
            '${entry.key}': <Map<String, Object?>>[
              for (final row in (entry.value as List? ?? const <Object?>[]))
                Map<String, Object?>.from(row as Map),
            ],
        },
        kv: <String, String>{
          for (final entry in (json['kv'] as Map? ?? const <String, Object?>{}).entries)
            '${entry.key}': '${entry.value}',
        },
      );

  final String? version;
  final Map<String, List<Map<String, Object?>>> tables;

  /// 插件写在 settings 里的 KV（键已去掉 `plg.<id>.` 前缀）
  final Map<String, String> kv;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'tables': tables,
        'kv': kv,
      };

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length) + kv.length;
}

/// 一份备份的全部内容
class BackupData {
  const BackupData({
    required this.manifest,
    required this.tasks,
    required this.tags,
    required this.taskTags,
    required this.recycled,
    required this.settings,
    required this.plugins,
  });

  final BackupManifest manifest;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> tags;

  /// 任务-标签关联。跟着「标签」那一段走：只恢复标签不恢复关联，
  /// 用户看到的是"标签都在，但一条任务都没打标签"。
  final List<Map<String, Object?>> taskTags;
  final List<Map<String, Object?>> recycled;
  final Map<String, String> settings;
  final Map<String, PluginBackup> plugins;
}

/// 库里现存的插件数据（备份页逐项勾选时用）
class PluginDataInfo {
  const PluginDataInfo({
    required this.pluginId,
    required this.tableCount,
    required this.rowCount,
    required this.installed,
    this.version,
  });

  final String pluginId;
  final int tableCount;
  final int rowCount;

  /// 是否在已装列表里。false 但 rowCount > 0 = 「已卸载，数据还在」
  final bool installed;
  final String? version;
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

/// 备份 / 恢复。
///
/// 判据一律是**"库里有没有这个插件的表"**，不是"装没装"：卸载时选了保留数据的
/// 插件，表还在、数据还在，按"装没装"判断会把它悄悄漏掉。
class BackupService {
  BackupService(this._db);

  final Database _db;

  static const String pluginTablePrefix = 'plg_';

  /// 库里现存的插件数据清单（含已卸载但留了数据的）
  ///
  /// **插件 id 不能靠"从表名里切第一个下划线"猜**：id 本身允许下划线
  /// （`energy_currency`），切出来会变成 `energy`。所以 id 只从两处权威来源取：
  /// `installed_plugins` 与 `plg_migrations`（插件建表时一定写了这一行）。
  Future<List<PluginDataInfo>> listPluginData() async {
    final installed = <String, String?>{
      for (final row in await _db.query(
        V6Table.installedPlugins,
        columns: <String>['plugin_id', 'version'],
      ))
        '${row['plugin_id']}': row['version'] as String?,
    };
    final migrated = <String>{
      for (final row in await _db.query(
        V6Table.pluginMigrations,
        columns: <String>['plugin_id'],
        distinct: true,
      ))
        '${row['plugin_id']}',
    };

    final ids = <String>{...installed.keys, ...migrated}..removeWhere((id) => id.isEmpty);
    final result = <PluginDataInfo>[];

    for (final id in ids) {
      final prefix = 'plg_${id}_';
      final tables = <String>[
        for (final row in await _db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE ? ESCAPE '?'",
          <Object?>['${prefix.replaceAll('_', '?_')}%'],
        ))
          '${row['name']}',
      ];
      var rows = 0;
      for (final table in tables) {
        rows += Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM "$table"')) ?? 0;
      }
      final kv = await _db.query(
        V6Table.settings,
        where: 'key LIKE ?',
        whereArgs: <Object?>['plg.$id.%'],
      );
      result.add(PluginDataInfo(
        pluginId: id,
        tableCount: tables.length,
        rowCount: rows + kv.length,
        installed: installed.containsKey(id),
        version: installed[id],
      ));
    }

    result.sort((a, b) => a.pluginId.compareTo(b.pluginId));
    return result;
  }

  /// 收集内容。[pluginIds] 为空表示不带任何插件数据。
  Future<BackupData> collect({
    required String appVersion,
    bool tasks = true,
    bool tags = true,
    bool settings = true,
    bool recycleBin = false,
    Set<String> pluginIds = const <String>{},
  }) async {
    final taskRows = tasks
        ? await _db.query(V6Table.tasks)
        : const <Map<String, Object?>>[];
    final tagRows = tags ? await _db.query(V6Table.tags) : const <Map<String, Object?>>[];
    final tagLinkRows =
        tags ? await _db.query(V6Table.taskTags) : const <Map<String, Object?>>[];
    final recycled =
        recycleBin ? await _db.query(V6Table.recycledTasks) : const <Map<String, Object?>>[];
    final settingRows = settings
        ? await _db.query(
            V6Table.settings,
            // 插件 KV 归到各自那一段，不混进主包设置里
            where: "key NOT LIKE 'plg.%'",
          )
        : const <Map<String, Object?>>[];

    final plugins = <String, PluginBackup>{};
    for (final id in pluginIds) {
      plugins[id] = await _collectPlugin(id);
    }

    final counts = <String, int>{
      if (tasks) 'tasks': taskRows.length,
      if (tags) 'tags': tagRows.length,
      if (recycleBin) 'recycled': recycled.length,
      if (settings) 'settings': settingRows.length,
      for (final entry in plugins.entries) 'plugin:${entry.key}': entry.value.rowCount,
    };

    return BackupData(
      manifest: BackupManifest(
        createdAt: DateTime.now().toUtc(),
        appVersion: appVersion,
        counts: counts,
        included: <String>[
          if (tasks) 'tasks',
          if (tags) 'tags',
          if (settings) 'settings',
          if (recycleBin) 'recycled',
          for (final id in plugins.keys) 'plugin:$id',
        ],
      ),
      tasks: taskRows,
      tags: tagRows,
      taskTags: tagLinkRows,
      recycled: recycled,
      settings: <String, String>{
        for (final row in settingRows) '${row['key']}': '${row['value']}',
      },
      plugins: plugins,
    );
  }

  Future<PluginBackup> _collectPlugin(String pluginId) async {
    final tables = <String, List<Map<String, Object?>>>{};
    final names = await _db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE ? ESCAPE '?'",
      <Object?>['plg_${pluginId}_%'],
    );
    for (final row in names) {
      final name = '${row['name']}';
      tables[name] = await _db.query(name);
    }
    final kvRows = await _db.query(
      V6Table.settings,
      where: 'key LIKE ?',
      whereArgs: <Object?>['plg.$pluginId.%'],
    );
    final prefix = 'plg.$pluginId.';
    final installed = await _db.query(
      V6Table.installedPlugins,
      columns: <String>['version'],
      where: 'plugin_id = ?',
      whereArgs: <Object?>[pluginId],
      limit: 1,
    );

    return PluginBackup(
      version: installed.isEmpty ? null : installed.first['version'] as String?,
      tables: tables,
      kv: <String, String>{
        for (final row in kvRows) '${row['key']}'.substring(prefix.length): '${row['value']}',
      },
    );
  }

  /// 打成一个 zip（里面 manifest.json + data.json）
  Uint8List pack(BackupData data) {
    final archive = Archive();
    void add(String name, Object? json) {
      final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(json));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add(BackupFormat.manifestEntry, data.manifest.toJson());
    add(BackupFormat.dataEntry, <String, Object?>{
      'tasks': data.tasks,
      'tags': data.tags,
      'taskTags': data.taskTags,
      'recycled': data.recycled,
      'settings': data.settings,
      'plugins': <String, Object?>{
        for (final entry in data.plugins.entries) entry.key: entry.value.toJson(),
      },
    });
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// 解包。不是本产品的文件、或格式比当前新，都抛 [BackupException]。
  BackupData unpack(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const BackupException('这个文件不是 zip，或者已经损坏');
    }

    String? readEntry(String name) {
      final file = archive.files.firstWhere(
        (f) => f.name == name,
        orElse: () => ArchiveFile(name, 0, <int>[]),
      );
      if (file.size == 0) return null;
      return utf8.decode(file.content as List<int>);
    }

    final manifestRaw = readEntry(BackupFormat.manifestEntry);
    if (manifestRaw == null) throw const BackupException('备份里缺少 manifest.json');
    final manifest = BackupManifest.fromJson(
      Map<String, Object?>.from(jsonDecode(manifestRaw) as Map),
    );

    final dataRaw = readEntry(BackupFormat.dataEntry);
    if (dataRaw == null) throw const BackupException('备份里缺少 data.json');
    final data = Map<String, Object?>.from(jsonDecode(dataRaw) as Map);

    List<Map<String, Object?>> rows(Object? value) => <Map<String, Object?>>[
          for (final row in (value as List? ?? const <Object?>[]))
            Map<String, Object?>.from(row as Map),
        ];

    return BackupData(
      manifest: manifest,
      tasks: rows(data['tasks']),
      tags: rows(data['tags']),
      taskTags: rows(data['taskTags']),
      recycled: rows(data['recycled']),
      settings: <String, String>{
        for (final entry in (data['settings'] as Map? ?? const <String, Object?>{}).entries)
          '${entry.key}': '${entry.value}',
      },
      plugins: <String, PluginBackup>{
        for (final entry in (data['plugins'] as Map? ?? const <String, Object?>{}).entries)
          '${entry.key}': PluginBackup.fromJson(Map<String, Object?>.from(entry.value as Map)),
      },
    );
  }

  /// 恢复。**覆盖语义**，不做合并（合并要处理任务 id 冲突、标签重名，
  /// 容易做成半成品；先给"覆盖 + 说清会丢什么"）。
  Future<RestoreReport> restore(
    BackupData data, {
    bool tasks = true,
    bool tags = true,
    bool settings = true,
    bool recycleBin = false,
    Set<String> pluginIds = const <String>{},
  }) async {
    final report = RestoreReport();

    await _db.transaction((txn) async {
      Future<void> writeRows(
        String label,
        String table,
        List<Map<String, Object?>> rows,
      ) async {
        await txn.delete(table);
        final columns = await _tableColumns(txn, table);
        var written = 0;
        for (final row in rows) {
          final filtered = <String, Object?>{};
          for (final entry in row.entries) {
            if (columns.contains(entry.key)) {
              filtered[entry.key] = entry.value;
            } else {
              // 备份是旧版本打的、后来删了列 —— 丢弃但要记进报告，别静默
              final key = '$table.${entry.key}';
              if (!report.droppedColumns.contains(key)) report.droppedColumns.add(key);
            }
          }
          if (filtered.isEmpty) continue;
          await txn.insert(table, filtered, conflictAlgorithm: ConflictAlgorithm.replace);
          written++;
        }
        report.written[label] = written;
      }

      if (tasks) {
        await writeRows('任务', V6Table.tasks, data.tasks);
        // 不恢复标签段时就该把关联清掉：任务都换了一批，旧的关联是悬空的
        if (!tags) await txn.delete(V6Table.taskTags);
      }
      if (tags) {
        await writeRows('标签', V6Table.tags, data.tags);
        await writeRows('标签关联', V6Table.taskTags, data.taskTags);
      }
      if (recycleBin) {
        await writeRows('回收站', V6Table.recycledTasks, data.recycled);
      }

      if (settings) {
        // **只覆盖备份里有的键，不清空整表**：表里还有更新器状态这类机器状态，
        // 整表清掉会让"已跳过的版本""上次检查时间"一起丢。
        for (final entry in data.settings.entries) {
          await txn.insert(
            V6Table.settings,
            <String, Object?>{SettingsCol.key: entry.key, SettingsCol.value: entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        report.written['设置'] = data.settings.length;
      }

      for (final id in pluginIds) {
        final plugin = data.plugins[id];
        if (plugin == null) continue;
        if (!await _restorePlugin(txn, id, plugin, report)) {
          report.skippedPlugins.add(id);
        }
      }
    });

    return report;
  }

  /// 恢复一个插件的段。返回 false = 整段跳过（没装、也没留下表）。
  Future<bool> _restorePlugin(
    DatabaseExecutor txn,
    String pluginId,
    PluginBackup plugin,
    RestoreReport report,
  ) async {
    final existing = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE ? ESCAPE '?'",
      <Object?>['plg_${pluginId}_%'],
    );
    final names = <String>{for (final row in existing) '${row['name']}'};
    if (names.isEmpty && plugin.tables.isNotEmpty) return false;

    var rows = 0;
    for (final entry in plugin.tables.entries) {
      final table = entry.key;
      if (!names.contains(table)) {
        // 备份里有这张表、现在没有：插件升级改过结构，或本来就没装
        report.skippedPlugins.add('$pluginId（缺表 $table）');
        continue;
      }
      await txn.delete(table);
      final columns = await _tableColumns(txn, table);
      for (final row in entry.value) {
        final filtered = <String, Object?>{};
        for (final cell in row.entries) {
          if (columns.contains(cell.key)) {
            filtered[cell.key] = cell.value;
          } else {
            final key = '$table.${cell.key}';
            if (!report.droppedColumns.contains(key)) report.droppedColumns.add(key);
          }
        }
        if (filtered.isEmpty) continue;
        await txn.insert(table, filtered, conflictAlgorithm: ConflictAlgorithm.replace);
        rows++;
      }
    }

    // KV 整段替换
    final prefix = 'plg.$pluginId.';
    await txn.delete(V6Table.settings, where: 'key LIKE ?', whereArgs: <Object?>['$prefix%']);
    for (final entry in plugin.kv.entries) {
      await txn.insert(
        V6Table.settings,
        <String, Object?>{SettingsCol.key: '$prefix${entry.key}', SettingsCol.value: entry.value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      rows++;
    }

    report.written['插件:$pluginId'] = rows;
    return true;
  }

  Future<Set<String>> _tableColumns(DatabaseExecutor txn, String table) async {
    final rows = await txn.rawQuery('PRAGMA table_info("$table")');
    return <String>{for (final row in rows) '${row['name']}'};
  }
}

/// 恢复结果。**不是一句"成功"**：丢了哪些列、跳过了哪些插件都要说清楚。
class RestoreReport {
  RestoreReport();

  final Map<String, int> written = <String, int>{};

  /// 备份里有、但当前表结构没有的列：`表.列`
  final List<String> droppedColumns = <String>[];

  /// 备份里有、当前没装也没表 → 整段跳过
  final List<String> skippedPlugins = <String>[];

  bool get hasLoss => droppedColumns.isNotEmpty || skippedPlugins.isNotEmpty;

  String get summary {
    final parts = <String>[
      for (final entry in written.entries) '${entry.key} ${entry.value}',
    ];
    return parts.join(' · ');
  }
}
