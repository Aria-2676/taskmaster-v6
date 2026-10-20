# 数据库契约 · v3

> 用途：Flutter 版与 RN 版之间的**唯一数据契约**。任何 schema 变更都必须同步更新本文件，并在文末追加版本记录。
> 来源：`lib/core/services/database/`（建表 `database_schema_mixin.dart`、迁移 `database_migration_*_mixin.dart`）。
> 基线：`AppConfig.dbVersion = 3`，文件 `v5_tasks.db`，路径 `/data/data/com.noteapp.taskmaster/databases/`。

---

## 1. 存储约定（RN 必须逐条对齐）

| 项 | 约定 | 说明 |
|---|---|---|
| 时间 | **ISO8601 字符串**，本地时区、**无时区后缀** | 来自 `DateTime.toIso8601String()`（本地时间），例 `2026-10-19T23:41:52.123456`。**不要**按 UTC 解析，也不要改存时间戳 |
| 布尔 | `INTEGER` 0 / 1 | 读取时 `== 1`，写入时 `? 1 : 0` |
| 积分 / 价格 | `INTEGER` | 无小数 |
| 颜色 | `INTEGER`，ARGB | 例 `0xFF9C27B0` |
| 枚举 | 小写字面量字符串 | 取值见 §3 |
| 主键 | `INTEGER PRIMARY KEY AUTOINCREMENT` | **迁移必须保留原 id**，否则 `related_id` / `task_tags` 全部错位 |
| 单行表 | `user_points.id = 1`、`pomodoro_settings.id = 1` | 有 `CHECK` / 约定，不允许第二行 |

> ⚠️ **时间的小数位数不统一，禁止按字符串严格相等比较时间。** Dart `toIso8601String()` 的规则是「微秒为 0 输出 3 位毫秒，非 0 输出 6 位微秒」，实测：`DateTime.now()` → `...T12:05:42.210140`（6 位）、`DateTime(2026,10,20,9,30,0)` → `...T09:30:00.000`（3 位）、`DateTime(2026,10,20,9,30,0,123)` → `...T09:30:00.123`（3 位）、`DateTime(2026,10,20,9,30,0,123,456)` → `...T09:30:00.123456`（6 位）。真机上 `DateTime.now()` 带微秒，绝大多数历史数据落在 **6 位**那一支；而 **RN 侧统一写 3 位**——JS 的 `Date` 只有毫秒精度，拿不到真实微秒，补随机值会破坏可复现性、补固定 `.000` 又会让所有 RN 写入行都挤进 3 位分支（与真实分布不一致），都不如诚实写 3 位。
>
> 因此：**排序 / 区间过滤 / `LIKE '____-__-__T__:__:%'` 前缀校验都仍然正确**（小数部分字典序等价于数值序），但**拿时间在 RN 写入行与 Flutter 历史行之间做 `=` 判等会失败**。需要判断「同一时刻」请比到秒（`SUBSTR(col, 1, 19)`）或转时间戳后再比。
>
> RN 侧对应实现：`rn/src/db/pomodoro.ts` 的 `nowLocalIso()`（本地时间手工拼串，不用 `toISOString()`）；同一段说明也写在该函数的 JSDoc 里。

---

## 2. 表结构（14 张）

### 2.1 `tasks` — 任务

| 列 | 类型 | 空 | 默认 | 语义 |
|---|---|---|---|---|
| `id` | INTEGER | PK | auto | |
| `loop_id` | TEXT | ✓ | — | 循环任务系列 id；同一次循环生成的实例共享 |
| `title` | TEXT | ✗ | — | |
| `description` | TEXT | ✓ | — | |
| `is_word` | INTEGER | ✗ | 0 | 是否「单词任务」 |
| `is_ok` | INTEGER | ✗ | 0 | 是否已完成 |
| `cpl_time` | TEXT | ✗ | — | 计划完成时间（ISO8601 本地） |
| `recurrence` | TEXT | ✗ | `'none'` | 重复规则，见 §3.1 |
| `completed_at` | TEXT | ✓ | — | 实际完成时间 |
| `reward_points` | INTEGER | ✗ | 0 | 完成可得的积分 |
| `is_deducted` | INTEGER | ✗ | 0 | 逾期积分是否已扣（幂等标记） |
| `created_at` | TEXT | ✗ | — | |
| `priority` | TEXT | ✗ | `'white'` | 见 §3.2 |

索引：`cpl_time`、`is_ok`、`recurrence`、`loop_id`、`completed_at`。

### 2.2 `recycled_tasks` — 回收站

字段与 `tasks` 相同（含 `loop_id`），额外：

| 列 | 类型 | 空 | 语义 |
|---|---|---|---|
| `task_id` | INTEGER | ✓ | 原任务 id（仅参考，不保证还能对上） |
| `deleted_at` | TEXT | ✗ | 删除时间 |

> v3 才补的 `loop_id`：没有它，循环任务从回收站恢复后不再生成后续实例（生成器在 `loopId` 为空时直接返回）。

### 2.3 `tags` / `task_tags`

| `tags` | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | |
| `name` | TEXT NOT NULL **UNIQUE** | 重名会被数据库拒绝 |
| `color` | TEXT | 形如 `'#2196F3'`（注意：字符串，不是 ARGB 整数） |
| `icon` | TEXT NULL | |
| `is_system` | INTEGER | 系统标签不可删 |
| `created_at` | TEXT | |

`task_tags`：`task_id` + `tag_id` 复合主键；声明了 `ON DELETE CASCADE`，**但代码从未执行 `PRAGMA foreign_keys=ON`**——见 §5 的坑。

### 2.4 积分相关

| `user_points` | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK，恒为 1 | |
| `points` | INTEGER | 当前余额 |
| `updated_at` | TEXT | |

| `points_records` | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | |
| `points` | INTEGER | **带符号**（扣分为负） |
| `type` | TEXT | 见 §3.3 |
| `description` | TEXT | 展示文案 |
| `related_id` | INTEGER NULL | 关联任务 / 彩票 id，按 `type` 解释 |
| `created_at` | TEXT | |

索引：`(type, related_id)`。

### 2.5 商城 / 仓库

| `shop_items` | 类型 | 默认 | |
|---|---|---|---|
| `id` / `name` / `description` / `price` / `created_at` | — | — | 商品定义 |
| `icon_name` | TEXT | `'shopping_bag'` | Material 图标名 |
| `color_value` | INTEGER | `0xFF9C27B0` | ARGB |

`purchased_items`：`id`、`shop_item_id`、`name`、`description`、`price`、`purchased_at`、`icon_name`、`color_value`。
**快照式存储**：改名/改价后历史记录不受影响，迁移时不要做「关联查询纠正」。

### 2.6 刮刮乐

| `custom_prize_pool` | 类型 | 默认 | |
|---|---|---|---|
| `id` | TEXT PK | — | 非自增 |
| `name` | TEXT | — | |
| `type` | TEXT | — | `'none'` 表示未中奖；其余取值见 §6 待实测 |
| `value` | INTEGER | — | 积分值 |
| `weight` | REAL | 1.0 | 权重 |
| `is_default` | INTEGER | 0 | |

`lottery_records`：`id`、`draw_time`、`prize_name`、`prize_type`、`prize_value`、`cost_points`、`created_at`。

`scratch_tickets`：`id`、`cost_points`、`prize_id`、`prize_name`、`prize_type`、`prize_value`、`created_at`、`is_scratched`、`is_revealed`。
> ⚠️ 后两列**没有 NOT NULL**（建表时只写了 `DEFAULT 0`）→ 库里可能存在 `NULL`。RN 读取必须按「`NULL` 视作 0」处理，不能断言非空。

### 2.7 番茄钟

| `pomodoro_records` | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | |
| `mode` | TEXT | `'work'` / `'shortBreak'` / `'longBreak'`（枚举名直存） |
| `duration_seconds` / `actual_seconds` | INTEGER | 计划 / 实际秒数 |
| `start_time` / `end_time` | TEXT | `end_time` 可空（中断） |
| `related_task_id` / `related_task_title` | INTEGER / TEXT | 标题也做快照 |
| `is_completed` | INTEGER | |
| `created_at` | TEXT | |

`pomodoro_settings`（单行，`CHECK (id = 1)`）：`work_duration=25`、`short_break_duration=5`、`long_break_duration=15`、`long_break_interval=4`、`sound_enabled=1`、`vibration_enabled=1`、`notification_enabled=1`、`auto_start_break=0`、`auto_start_work=0`（时长单位：**分钟**）。

### 2.8 `settings` — 键值表

`key TEXT PRIMARY KEY`，`value TEXT NOT NULL`。已观测到的键（值均为字符串）：

`taskViewMode`、`taskCreateMode`、`themeMode`、`rememberFilters`、`allowEditPastTasks`、`allowCompletePastTasks`、`priority`、`recurrence`、`rewardPoints`、`isWord`、`description`、`date`

> 键名是 **camelCase**（v1 遗留），与表列名的蛇形风格不一致——迁移时别顺手改名。

---

## 3. 枚举取值

### 3.1 `recurrence`
`none`（默认）｜`daily`｜`weekly`｜`monthly`
> 生成下一实例的逻辑只认这四种，`default` 分支直接返回。`yearly` **不存在**。

### 3.2 `priority`
`red`｜`orange`｜`yellow`｜`blue`｜`white`（默认）
> 按自然灾害预警色分级，任务列表按此排序。

### 3.3 `points_records.type`
`task_complete`｜`task_uncomplete`｜`overdue_deduct`｜`scratch_win`｜`scratch_refund`｜`shop_purchase`｜`scratch_cost`

> ⚠️ **实为 7 种，不是 5 种**（`spec-points-shop.md` A.3 / G1 已核实）。漏掉的两条恰好是
> **商城与刮刮乐的主流水类型**。`related_id` 的指向随 type 变化：
> 任务类 → `tasks.id`；`shop_purchase` → **`shop_items.id`**（不是 `purchased_items.id`）；
> `scratch_win` / `scratch_refund` → **NULL**（`scratch_play_mixin.dart:202`/`:225` 没传 relatedId）。
> 与 `related_id` 的对应：任务类 → `tasks.id`；刮刮乐类 → `scratch_tickets.id` 或奖池 id（按写入处）。

### 3.4 `pomodoro_records.mode`
`work`｜`shortBreak`｜`longBreak`

---

## 4. 索引（8 条，RN 侧等价建）

```sql
CREATE INDEX IF NOT EXISTS idx_tasks_cpl_time          ON tasks(cpl_time);
CREATE INDEX IF NOT EXISTS idx_tasks_is_ok             ON tasks(is_ok);
CREATE INDEX IF NOT EXISTS idx_tasks_recurrence        ON tasks(recurrence);
CREATE INDEX IF NOT EXISTS idx_tasks_loop_id           ON tasks(loop_id);
CREATE INDEX IF NOT EXISTS idx_tasks_completed_at      ON tasks(completed_at);
CREATE INDEX IF NOT EXISTS idx_points_records_type_related ON points_records(type, related_id);
CREATE INDEX IF NOT EXISTS idx_pomodoro_start_time     ON pomodoro_records(start_time);
CREATE INDEX IF NOT EXISTS idx_task_tags_tag_id        ON task_tags(tag_id);
```

---

## 5. 迁移不变量（RN 必须遵守，违反即数据损坏）

1. **id 原样保留**，不要重新分配；`AUTOINCREMENT` 的 `sqlite_sequence` 也建议一并带过去（否则新插入可能撞 id）。
2. **单行表结构**：`user_points` 与 `pomodoro_settings` 只能有 `id = 1` 一行。
3. **时间不改格式**：ISO8601 本地时间字符串。若 RN 侧用毫秒时间戳，必须在读写边界统一转换，不能混存。
4. **`task_tags` 很可能有孤儿行**：代码从未开启 `PRAGMA foreign_keys=ON`，声明的 `ON DELETE CASCADE` **大概率没有真正生效**。迁移时不要假设外键已清理，应先跑 §7 的孤立行检查。
5. **`scratch_tickets.is_scratched / is_revealed` 可能为 NULL**，按 0 处理。
6. **`settings` 键名是 camelCase**，保持原样，不要「统一风格」。
7. **`purchased_items` 是快照**，不要与 `shop_items` 做关联纠正。

---

## 6. 待实测（迁移前必须回填本节）

| # | 未知项 | 怎么测 |
|---|---|---|
| 1 | `custom_prize_pool.type` 的完整取值集合 | `SELECT type, COUNT(*) FROM custom_prize_pool GROUP BY type;` |
| 2 | 实际 `journal_mode`（是否 WAL） | `PRAGMA journal_mode;` |
| 3 | `task_tags` 是否存在孤儿行 | §7 第 3 条 |
| 4 | 是否存在 `cpl_time` / `created_at` 格式异常的脏数据 | §7 第 4 条 |
| 5 | `settings` 实际有多少键、有无历史遗留键 | `SELECT key FROM settings ORDER BY key;` |

---

## 7. 迁移验收查询（旧库与新库各跑一遍，结果必须完全一致）

```sql
-- 1) 行数
SELECT 'tasks', COUNT(*) FROM tasks
UNION ALL SELECT 'recycled_tasks', COUNT(*) FROM recycled_tasks
UNION ALL SELECT 'tags', COUNT(*) FROM tags
UNION ALL SELECT 'task_tags', COUNT(*) FROM task_tags
UNION ALL SELECT 'points_records', COUNT(*) FROM points_records
UNION ALL SELECT 'shop_items', COUNT(*) FROM shop_items
UNION ALL SELECT 'purchased_items', COUNT(*) FROM purchased_items
UNION ALL SELECT 'pomodoro_records', COUNT(*) FROM pomodoro_records
UNION ALL SELECT 'custom_prize_pool', COUNT(*) FROM custom_prize_pool
UNION ALL SELECT 'lottery_records', COUNT(*) FROM lottery_records
UNION ALL SELECT 'scratch_tickets', COUNT(*) FROM scratch_tickets
UNION ALL SELECT 'settings', COUNT(*) FROM settings;

-- 2) 余额与积分流水净额（必须相等）
SELECT (SELECT points FROM user_points WHERE id = 1) AS balance,
       (SELECT COALESCE(SUM(points), 0) FROM points_records) AS ledger_sum;

-- 3) 孤儿关联（应为 0）
--    ⚠️ 口径：回收站里的任务在 `tasks` 中没有对应行，但它的标签关联**不是孤儿**
--    （恢复任务时靠这行关联自动接回标签）。所以孤儿 = 在 tasks 与 recycled_tasks 中都找不到。
SELECT COUNT(*) FROM task_tags tt
  LEFT JOIN tasks t ON t.id = tt.task_id
  LEFT JOIN recycled_tasks r ON r.task_id = tt.task_id
 WHERE t.id IS NULL AND r.id IS NULL;
SELECT COUNT(*) FROM task_tags tt
  LEFT JOIN tags g ON g.id = tt.tag_id WHERE g.id IS NULL;

-- 4) 时间格式抽样（应全部匹配）
SELECT COUNT(*) FROM tasks
 WHERE cpl_time NOT LIKE '____-__-__T__:__:%'
    OR created_at NOT LIKE '____-__-__T__:__:%';

-- 5) 完整性
PRAGMA integrity_check;
```

**判定标准**：1、2、3、5 必须完全一致；4 的计数只允许「迁移前后相同」，不允许变大。

**执行时序**：本节在**迁移完成时立即执行**，用于证明迁移本身没引入任何数据变更。
应用运行后的孤儿清理（`purgeOrphanTaskTags()`）**不参与本验收**——它发生在验收之后，
且它只在「回收站清空」或用户手动触发时才运行，**不会在启动时自动执行**
（自动执行会让本节的结果不可预测）。

---

## 8. 版本历史

| 版本 | 变更 | 迁移方式 |
|---|---|---|
| v1 | 初始，字段为 camelCase | — |
| v2 | 12 张表字段全部改为 snake_case | 每表 `CREATE _new` + `INSERT SELECT` + `DROP` + `RENAME`（minSdk 21 不支持 `RENAME COLUMN`），完成后重建索引 |
| v3 | `recycled_tasks` 补 `loop_id` | `PRAGMA table_info` 检查后 `ALTER TABLE ADD COLUMN`（幂等） |

> v2 的列改名对照（旧 → 新）：`loopId→loop_id`、`isWord→is_word`、`isOK→is_ok`、`cplTime→cpl_time`、`completedAt→completed_at`、`rewardPoints→reward_points`、`isDeducted→is_deducted`、`createdAt→created_at`、`shop_item_id` 类同、`colorValue→color_value`、`iconName→icon_name`、`purchasedAt→purchased_at`、`drawTime→draw_time`、`prizeName→prize_name`、`prizeType→prize_type`、`prizeValue→prize_value`、`costPoints→cost_points`、`isSystem→is_system`、`durationSeconds→duration_seconds`、`actualSeconds→actual_seconds`、`startTime→start_time`、`endTime→end_time`、`relatedTaskId→related_task_id`、`relatedTaskTitle→related_task_title`、`isCompleted→is_completed`、`workDuration→work_duration` 等。

---

## 9. 维护约定

- 改 schema = 改本文件 + `dbVersion +1` + 写迁移步骤，三者缺一不可。
- 真实数据与样本**绝不入库**（仓库公开）：样本放 `/fixtures/`（已 gitignore），进仓库前必须脱敏。
- 本文件是契约，不是实现说明；实现细节仍以 `lib/core/services/database/` 为准，两者不一致时以代码为准并立刻修正本文件。
