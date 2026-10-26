// v6 数据层 —— 主包 schema 定义。
//
// 与 v5 的差别（docs/main-package.md §5）：
//   1. `tasks` **不再有** `reward_points` / `is_deducted` —— 货币字段归货币插件自己的表
//   2. `tasks` 新增 `estimated_minutes`（可空的预计工时，供货币插件计价）
//   3. 没有迁移链：`version` 从 1 开始，v5 的历史版本号不再延续
//   4. 已切给插件的 5 张表（商城 / 刮刮乐）不在这里
//
// 列名一律用常量，SQL 里不出现裸字符串（避免拼错只有运行时才发现）。

/// 主包表名。
class V6Table {
  const V6Table._();

  static const String tasks = 'tasks';
  static const String recycledTasks = 'recycled_tasks';
  static const String tags = 'tags';
  static const String taskTags = 'task_tags';
  static const String settings = 'settings';

  /// 插件表迁移记录（基础设施表，不属于任何业务）
  static const String pluginMigrations = 'plg_migrations';

  /// 已安装插件登记表（基础设施表）。**宿主**的信息，不是插件自己的表，
  /// 所以不加 `plg_` 前缀 —— 那个前缀是留给插件私有表的。
  static const String installedPlugins = 'installed_plugins';

  /// 事件日志（基础设施表）。插件没挂载时收到的事件先落这里，
  /// 下次挂载时补发、确认后删除。**不是插件的表**，所以同样不加 `plg_` 前缀。
  static const String pluginEvents = 'plugin_events';

  /// v5 遗留、v6 已移出的表名。保留常量是为了让"已移出"这件事可被测试断言。
  ///
  /// - 商城/刮刮乐 → 各自插件的 `plg_shop_*` / `plg_scratch_*`
  /// - 番茄钟 → 插件的 `plg_pomodoro_*`（会话记录属于插件；
  ///   主包计时引擎只把"正在计时"的运行时状态放在 `settings` 里）
  static const String legacyPomodoroRecords = 'pomodoro_records';
  static const String legacyPomodoroSettings = 'pomodoro_settings';

  /// 主包业务表（不含 [pluginMigrations]）
  static const List<String> businessTables = <String>[
    tasks,
    recycledTasks,
    tags,
    taskTags,
    settings,
  ];
}

class TaskCol {
  const TaskCol._();

  static const String id = 'id';
  static const String loopId = 'loop_id';
  static const String title = 'title';
  static const String description = 'description';
  static const String isWord = 'is_word';
  static const String isOk = 'is_ok';
  static const String cplTime = 'cpl_time';
  static const String recurrence = 'recurrence';
  static const String completedAt = 'completed_at';
  static const String estimatedMinutes = 'estimated_minutes';
  static const String createdAt = 'created_at';
  static const String priority = 'priority';

  /// v5 遗留、v6 明确移除的列。保留常量是为了让"已移除"这件事可被测试断言。
  static const String legacyRewardPoints = 'reward_points';
  static const String legacyIsDeducted = 'is_deducted';
}

class RecycledTaskCol {
  const RecycledTaskCol._();

  static const String id = 'id';
  static const String taskId = 'task_id';
  static const String loopId = 'loop_id';
  static const String title = 'title';
  static const String description = 'description';
  static const String isWord = 'is_word';
  static const String isOk = 'is_ok';
  static const String cplTime = 'cpl_time';
  static const String recurrence = 'recurrence';
  static const String completedAt = 'completed_at';
  static const String estimatedMinutes = 'estimated_minutes';
  static const String createdAt = 'created_at';
  static const String priority = 'priority';
  static const String deletedAt = 'deleted_at';

  /// 该任务被删时拥有的标签 id，逗号分隔（`1,3,7`）。
  ///
  /// 存快照而不是靠 `task_tags` 保留：那张表有 `ON DELETE CASCADE`，
  /// 删任务时会被级联清掉。恢复时按这里重建，但只重建仍然存在的标签
  /// （标签可能在这期间被删了，外键会拒绝整条恢复）。
  static const String tagIds = 'tag_ids';
}

class TagCol {
  const TagCol._();

  static const String id = 'id';
  static const String name = 'name';
  static const String color = 'color';
  static const String icon = 'icon';
  static const String isSystem = 'is_system';
  static const String createdAt = 'created_at';
}

class TaskTagCol {
  const TaskTagCol._();

  static const String taskId = 'task_id';
  static const String tagId = 'tag_id';
}

class SettingsCol {
  const SettingsCol._();

  static const String key = 'key';
  static const String value = 'value';
}

class InstalledPluginCol {
  const InstalledPluginCol._();

  static const String pluginId = 'plugin_id';
  static const String version = 'version';
  static const String contract = 'contract';

  /// 安装目录，相对插件根目录（如 `pomodoro/1.0.0`）
  static const String installDir = 'install_dir';
  static const String installedAt = 'installed_at';
  static const String enabled = 'enabled';
}

class PluginMigrationCol {
  const PluginMigrationCol._();

  static const String pluginId = 'plugin_id';
  static const String tableName = 'table_name';
  static const String version = 'version';
  static const String createdAt = 'created_at';
}

/// 已安装插件表。**单独拎出来**，因为它需要在每次打开库时幂等补建 ——
/// schema 建好之后才加的表，老设备上不会有，又不能为此升 dbVersion。
const String v6InstalledPluginsDdl = '''
  CREATE TABLE IF NOT EXISTS ${V6Table.installedPlugins} (
    ${InstalledPluginCol.pluginId} TEXT PRIMARY KEY,
    ${InstalledPluginCol.version} TEXT NOT NULL,
    ${InstalledPluginCol.contract} INTEGER NOT NULL,
    ${InstalledPluginCol.installDir} TEXT NOT NULL,
    ${InstalledPluginCol.installedAt} TEXT NOT NULL,
    ${InstalledPluginCol.enabled} INTEGER NOT NULL DEFAULT 1
  )
  ''';

class PluginEventCol {
  const PluginEventCol._();

  static const String id = 'id';
  static const String hook = 'hook';
  static const String payload = 'payload';
  static const String createdAt = 'created_at';
}

/// 事件日志表。和 [v6InstalledPluginsDdl] 一样，打开库时幂等补建。
///
/// 只存**还没被插件确认**的事件。插件 ack 之后就删 —— 这张表不该变成历史归档，
/// 它只是个投递队列。
const String v6PluginEventsDdl = '''
  CREATE TABLE IF NOT EXISTS ${V6Table.pluginEvents} (
    ${PluginEventCol.id} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${PluginEventCol.hook} TEXT NOT NULL,
    ${PluginEventCol.payload} TEXT NOT NULL,
    ${PluginEventCol.createdAt} TEXT NOT NULL
  )
  ''';

/// 建表语句。顺序有意义：被引用的表先建（`task_tags` 依赖 `tasks` 与 `tags`）。
const List<String> v6CreateTables = <String>[
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.tasks} (
    ${TaskCol.id} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${TaskCol.loopId} TEXT,
    ${TaskCol.title} TEXT NOT NULL,
    ${TaskCol.description} TEXT,
    ${TaskCol.isWord} INTEGER NOT NULL DEFAULT 0,
    ${TaskCol.isOk} INTEGER NOT NULL DEFAULT 0,
    ${TaskCol.cplTime} TEXT NOT NULL,
    ${TaskCol.recurrence} TEXT NOT NULL DEFAULT 'none',
    ${TaskCol.completedAt} TEXT,
    ${TaskCol.estimatedMinutes} INTEGER,
    ${TaskCol.createdAt} TEXT NOT NULL,
    ${TaskCol.priority} TEXT NOT NULL DEFAULT 'white'
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.recycledTasks} (
    ${RecycledTaskCol.id} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${RecycledTaskCol.taskId} INTEGER,
    ${RecycledTaskCol.loopId} TEXT,
    ${RecycledTaskCol.title} TEXT NOT NULL,
    ${RecycledTaskCol.description} TEXT,
    ${RecycledTaskCol.isWord} INTEGER NOT NULL DEFAULT 0,
    ${RecycledTaskCol.isOk} INTEGER NOT NULL DEFAULT 0,
    ${RecycledTaskCol.cplTime} TEXT NOT NULL,
    ${RecycledTaskCol.recurrence} TEXT NOT NULL DEFAULT 'none',
    ${RecycledTaskCol.completedAt} TEXT,
    ${RecycledTaskCol.estimatedMinutes} INTEGER,
    ${RecycledTaskCol.createdAt} TEXT NOT NULL,
    ${RecycledTaskCol.priority} TEXT NOT NULL DEFAULT 'white',
    ${RecycledTaskCol.deletedAt} TEXT NOT NULL,
    ${RecycledTaskCol.tagIds} TEXT
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.tags} (
    ${TagCol.id} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${TagCol.name} TEXT NOT NULL UNIQUE,
    ${TagCol.color} TEXT NOT NULL DEFAULT '#2196F3',
    ${TagCol.icon} TEXT,
    ${TagCol.isSystem} INTEGER NOT NULL DEFAULT 0,
    ${TagCol.createdAt} TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.taskTags} (
    ${TaskTagCol.taskId} INTEGER NOT NULL,
    ${TaskTagCol.tagId} INTEGER NOT NULL,
    PRIMARY KEY (${TaskTagCol.taskId}, ${TaskTagCol.tagId}),
    FOREIGN KEY (${TaskTagCol.taskId}) REFERENCES ${V6Table.tasks}(${TaskCol.id}) ON DELETE CASCADE,
    FOREIGN KEY (${TaskTagCol.tagId}) REFERENCES ${V6Table.tags}(${TagCol.id}) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.settings} (
    ${SettingsCol.key} TEXT PRIMARY KEY,
    ${SettingsCol.value} TEXT NOT NULL
  )
  ''',
  v6InstalledPluginsDdl,
  '''
  CREATE TABLE IF NOT EXISTS ${V6Table.pluginMigrations} (
    ${PluginMigrationCol.pluginId} TEXT NOT NULL,
    ${PluginMigrationCol.tableName} TEXT NOT NULL,
    ${PluginMigrationCol.version} INTEGER NOT NULL,
    ${PluginMigrationCol.createdAt} TEXT NOT NULL,
    PRIMARY KEY (${PluginMigrationCol.pluginId}, ${PluginMigrationCol.tableName})
  )
  ''',
];

/// 索引。
const List<String> v6CreateIndexes = <String>[
  'CREATE INDEX IF NOT EXISTS idx_tasks_cpl_time ON ${V6Table.tasks}(${TaskCol.cplTime})',
  'CREATE INDEX IF NOT EXISTS idx_tasks_is_ok ON ${V6Table.tasks}(${TaskCol.isOk})',
  'CREATE INDEX IF NOT EXISTS idx_tasks_recurrence ON ${V6Table.tasks}(${TaskCol.recurrence})',
  'CREATE INDEX IF NOT EXISTS idx_tasks_loop_id ON ${V6Table.tasks}(${TaskCol.loopId})',
  'CREATE INDEX IF NOT EXISTS idx_tasks_completed_at ON ${V6Table.tasks}(${TaskCol.completedAt})',
  'CREATE INDEX IF NOT EXISTS idx_task_tags_tag_id ON ${V6Table.taskTags}(${TaskTagCol.tagId})',
];
