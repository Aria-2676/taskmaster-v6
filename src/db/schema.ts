/**
 * 数据库结构（v3）—— 与 docs/migration/schema-v3.md 一一对应。
 *
 * 这里是 RN 侧的「建库脚本」，只在**全新安装**时执行。
 * 已有用户升级时走的是「打开旧库 + 迁移」，不重建表。
 */

export const SCHEMA_VERSION = 3;

export const CREATE_TABLES = `
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  loop_id TEXT,
  title TEXT NOT NULL,
  description TEXT,
  is_word INTEGER NOT NULL DEFAULT 0,
  is_ok INTEGER NOT NULL DEFAULT 0,
  cpl_time TEXT NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  completed_at TEXT,
  reward_points INTEGER NOT NULL DEFAULT 0,
  is_deducted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'white'
);
CREATE TABLE IF NOT EXISTS shop_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  price INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  icon_name TEXT NOT NULL DEFAULT 'shopping_bag',
  color_value INTEGER NOT NULL DEFAULT 4278190335
);
CREATE TABLE IF NOT EXISTS user_points (
  id INTEGER PRIMARY KEY DEFAULT 1,
  points INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS points_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  points INTEGER NOT NULL,
  type TEXT NOT NULL,
  description TEXT NOT NULL,
  related_id INTEGER,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS purchased_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  shop_item_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  price INTEGER NOT NULL,
  purchased_at TEXT NOT NULL,
  icon_name TEXT NOT NULL DEFAULT 'shopping_bag',
  color_value INTEGER NOT NULL DEFAULT 4278190335
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS recycled_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER,
  loop_id TEXT,
  title TEXT NOT NULL,
  description TEXT,
  is_word INTEGER NOT NULL DEFAULT 0,
  is_ok INTEGER NOT NULL DEFAULT 0,
  cpl_time TEXT NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  completed_at TEXT,
  reward_points INTEGER NOT NULL DEFAULT 0,
  is_deducted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'white',
  deleted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS custom_prize_pool (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  value INTEGER NOT NULL,
  weight REAL NOT NULL DEFAULT 1.0,
  is_default INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS lottery_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  draw_time TEXT NOT NULL,
  prize_name TEXT NOT NULL,
  prize_type TEXT NOT NULL,
  prize_value INTEGER NOT NULL,
  cost_points INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color TEXT NOT NULL DEFAULT '#2196F3',
  icon TEXT,
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_tags (
  task_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  PRIMARY KEY (task_id, tag_id),
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS pomodoro_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mode TEXT NOT NULL,
  duration_seconds INTEGER NOT NULL,
  actual_seconds INTEGER NOT NULL,
  start_time TEXT NOT NULL,
  end_time TEXT,
  related_task_id INTEGER,
  related_task_title TEXT,
  is_completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pomodoro_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  work_duration INTEGER NOT NULL DEFAULT 25,
  short_break_duration INTEGER NOT NULL DEFAULT 5,
  long_break_duration INTEGER NOT NULL DEFAULT 15,
  long_break_interval INTEGER NOT NULL DEFAULT 4,
  sound_enabled INTEGER NOT NULL DEFAULT 1,
  vibration_enabled INTEGER NOT NULL DEFAULT 1,
  notification_enabled INTEGER NOT NULL DEFAULT 1,
  auto_start_break INTEGER NOT NULL DEFAULT 0,
  auto_start_work INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS scratch_tickets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cost_points INTEGER NOT NULL,
  prize_id TEXT NOT NULL,
  prize_name TEXT NOT NULL,
  prize_type TEXT NOT NULL,
  prize_value INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  is_scratched INTEGER DEFAULT 0,
  is_revealed INTEGER DEFAULT 0
);
`;

export const CREATE_INDEXES = `
CREATE INDEX IF NOT EXISTS idx_tasks_cpl_time ON tasks(cpl_time);
CREATE INDEX IF NOT EXISTS idx_tasks_is_ok ON tasks(is_ok);
CREATE INDEX IF NOT EXISTS idx_tasks_recurrence ON tasks(recurrence);
CREATE INDEX IF NOT EXISTS idx_tasks_loop_id ON tasks(loop_id);
CREATE INDEX IF NOT EXISTS idx_tasks_completed_at ON tasks(completed_at);
CREATE INDEX IF NOT EXISTS idx_points_records_type_related ON points_records(type, related_id);
CREATE INDEX IF NOT EXISTS idx_pomodoro_start_time ON pomodoro_records(start_time);
CREATE INDEX IF NOT EXISTS idx_task_tags_tag_id ON task_tags(tag_id);
`;

/**
 * 初始数据：与 Flutter 版保持一致（单行表 + 4 个系统标签）。
 *
 * ⚠️ 这段只在**全新安装**时执行；已有数据的用户走「打开旧库 + 迁移」，不跑种子。
 *
 * 🔧 H13（这是**修**，与 Flutter 版对齐）：Flutter 首装会插 4 个系统标签，
 * **RN 侧原本漏了**，导致「单词」联动 `is_word` 在 RN 上**直接失效**——
 * 因为 `is_word` 是由「单词」标签的勾选状态派生的，标签不存在就无从派生。
 *
 * 两条实现细节：
 * - **不硬编码 `id`**：靠 `AUTOINCREMENT` 分配。全新安装时表是空的，
 *   结果与 Flutter 一致（1–4），但硬编码会在「表非空但缺这几个标签」的库上
 *   撞主键而整条种子失败。
 * - 用 `INSERT OR IGNORE`：`tags.name` 是 `NOT NULL UNIQUE`，
 *   重复执行时靠它静默跳过，而不是抛「已存在同名记录」。
 *
 * `created_at` 用与上方 `user_points` 相同的 `strftime(..., 'localtime')` 写法，
 * 产出 `YYYY-MM-DDTHH:MM:SS.mmm` 本地时间串（符合 schema-v3 §1，无时区后缀）。
 */
export const SEED_SQL = `
INSERT OR IGNORE INTO user_points (id, points, updated_at)
VALUES (1, 0, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'));
INSERT OR IGNORE INTO pomodoro_settings (id) VALUES (1);
INSERT OR IGNORE INTO tags (name, color, icon, is_system, created_at)
VALUES ('单词', '#FF9800', 'translate', 1, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'));
INSERT OR IGNORE INTO tags (name, color, icon, is_system, created_at)
VALUES ('工作', '#2196F3', 'work', 1, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'));
INSERT OR IGNORE INTO tags (name, color, icon, is_system, created_at)
VALUES ('学习', '#4CAF50', 'school', 1, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'));
INSERT OR IGNORE INTO tags (name, color, icon, is_system, created_at)
VALUES ('生活', '#9C27B0', 'home', 1, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'));

-- 商城默认商品（Flutter 侧是运行时播种；这里改成**首次启动播种**，
-- 因为新 app 全新安装时没有任何商品，商城会是空的）。
-- 数据取自作者真实库（noteapp_backup_wu_2026_09_10）。「color_value「 是 ARGB 整数。
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('休息15分钟', '兑换后可以休息15分钟，放松身心', 50, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'local_cafe', 4286141768);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('看一集动漫', '奖励自己看一集喜欢的动漫', 100, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'movie', 4293467747);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('吃一块蛋糕', '兑换一块美味的蛋糕奖励自己', 80, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'cake', 4294940672);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('玩游戏30分钟', '兑换30分钟游戏时间', 120, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'sports_esports', 4288423856);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('买一本书', '兑换购买一本心仪的书籍', 200, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'book', 4283215696);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('周末旅行', '兑换一次周末短途旅行', 500, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'flight', 4280391411);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('买新装备', '兑换购买新的电子设备或配件', 300, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'laptop', 4284513675);
INSERT OR IGNORE INTO shop_items (name, description, price, created_at, icon_name, color_value)
VALUES ('SPA放松', '兑换一次SPA按摩放松', 400, strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'), 'spa', 4278238420);

-- 设置默认值（Flutter 侧运行时写入；这里改成首次启动播种，
-- 否则新装的 app 读不到 「themeMode「 / 「taskSortOption「 等，会退回硬编码默认）。
INSERT OR IGNORE INTO settings (key, value) VALUES ('allowCompletePastTasks', 'true');
INSERT OR IGNORE INTO settings (key, value) VALUES ('allowEditPastTasks', 'true');
INSERT OR IGNORE INTO settings (key, value) VALUES ('enabledCreateFields', 'description,rewardPoints,date,recurrence,priority');
INSERT OR IGNORE INTO settings (key, value) VALUES ('enabledEditFields', 'description,rewardPoints,date,recurrence,priority');
INSERT OR IGNORE INTO settings (key, value) VALUES ('lastCompletionFilter', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('lastPriorityFilter', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('lastRecurrenceFilter', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('lastTagFilterId', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('profilePinnedSettings', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('rememberFilters', 'true');
INSERT OR IGNORE INTO settings (key, value) VALUES ('settingsPinnedSettings', '');
INSERT OR IGNORE INTO settings (key, value) VALUES ('taskCreateMode', 'full');
INSERT OR IGNORE INTO settings (key, value) VALUES ('taskEditMode', 'full');
INSERT OR IGNORE INTO settings (key, value) VALUES ('taskSortOption', 'defaultOrder');
INSERT OR IGNORE INTO settings (key, value) VALUES ('taskViewMode', 'simple');
INSERT OR IGNORE INTO settings (key, value) VALUES ('themeMode', 'light');
`;
