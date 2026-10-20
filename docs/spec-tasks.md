# 任务模块行为规格 · Flutter → React Native 1:1 重写

> 读者：没读过这份 Dart 代码、但要照着写 RN 的人。
> 范围：`lib/modules/tasks/`（30 文件）+ `lib/providers/mixins/task_*.dart` + `lib/providers/task_provider.dart` + `lib/core/utils/task_sort_utils.dart` + 相关 `lib/core/services/database/` 片段。
> 契约：`docs/migration/schema-v3.md`（数据契约）、`docs/migration/business-rules.md`（业务规则）。
> **本文档描述的是代码的真实行为。凡与上述两份文档冲突处，均在 §6 单独列出，并给出「以哪个为准」的裁决。**

**可直接复用、不要重写的 RN 侧资产：**

| 资产 | 位置 | 覆盖范围 |
|---|---|---|
| `generateInstanceDates()` / `instanceKey()` / `pickNewDates()` / `generateLoopId()` | `rn/src/core/recurrence.ts` | 本文 §4 循环任务全部日期规则 |
| `resolveCompletion()` / `resolveUncompletion()` / `resolveOverdueDeduction()` | `rn/src/core/points.ts` | 本文 §3.2/3.3/3.5 积分结算判定 |
| `nowLocalIso()` / `isoMinute()` / `localTodayRange()` / `toBool()` / `fromBool()` / `writeBatch()` / `queryAll()` | `rn/src/repo/base.ts` | 时间格式与 0/1↔boolean 映射 |
| `TaskRow` / `RecycledTaskRow` / `Priority` / `Recurrence` | `rn/src/repo/types.ts` | 行类型（⚠️ 有 3 处字段名错误，见 §6.4） |

---

## 0. 模块地图与依赖方向

```
UI 层（Flutter）                     状态层                        数据层
tasks_home_page.dart      ┐
  └ task_page.dart        │
      ├ *_card_widget     ├─→ TaskProvider ─→ TaskRepository ─→ DatabaseGateway(sqflite)
      ├ task_form_widget  │   (ChangeNotifier,  (Impl)              │
      ├ menu_panel_widget │    7 个 mixin)                        ├─ points: PointsProvider
      ├ recycle_bin_page  ┘        │                              └─ tags:   TagProvider
      └ (dialogs mixin)             └─→ TaskSchedulerService ──────→ 同上事务
```

RN 侧建议保持同构：`TaskRepository`（纯 SQL，无业务） → `TaskSchedulerService`（循环生成） → `TaskStore`（对应 TaskProvider 的内存状态） → 页面。

**已确认为死代码，不要在 RN 里实现：**

| 文件/成员 | 证据 |
|---|---|
| `lib/modules/tasks/services/task_service.dart` 整个 `TaskService` | 全仓 grep `TaskService` 只命中自身定义，**无任何 import、无任何实例化**。其 `handleRecurringTasks()`/`_createNextRecurrence()` 是循环任务的**旧实现**，与现行的 `TaskSchedulerService` 语义不同（见 §6.1），照抄会引入 bug。 |
| `lib/core/services/database/database_task_mixin.dart` 的 `moveTaskToRecycleBin()` | `TaskRepositoryImpl.deleteTask()` 才是回收站运行时路径。⚠️ `moveTaskToRecycleBin()` **不搬 `loop_id`**，测试里已把这条标为「已知行为」（`test/core/database_task_mixin_test.dart:254`，且该测试是在**断言这个缺陷存在**：`expect(restored.loopId, isNull)`）。 |
| `DatabaseTaskMixin` 的其余 5 个回收站方法 | **无调用方**：`deleteTaskWithoutRecycle()`(mixin:238)、`_cleanupRecycledTasksTxn()`(mixin:244，仅被同为死代码的 :232 调用 → 传递性死亡)、`restoreTaskFromRecycle()`(mixin:263)、`deleteFromRecycle()`(mixin:305)、`clearRecycleBin()`(mixin:314)。回收站全部运行时路径都在 `TaskRepositoryImpl`。 |
| ⚠️ **`getRecycledTasks()` 不在死代码清单里——两个同名实现都是活代码** | 见下方专段。**这是最容易误判的一处，QA 独立核查已确认。** |
| `TaskProvider.setSearchQuery()` | 唯一读取方 `searchQuery` 只用于 `MenuPanelWidget.initState` 的初值和 `EmptyStateWidget` 的分支判断，UI 从不调用 setter → **`_searchQuery` 恒为 `''`**，见 §6.2。 |
| `TaskProvider.toggleSelectedDate()` / `setMultiTaskMode()` / `multiTaskMode` | 无调用方。多选日期功能实际不存在。 |
| `TaskProvider.exitSearchMode()` | 只被 `MenuPanelWidget._exitSearchMode` 调用（清除 `isSearchMode`，该字段本身也无 UI 消费者）。 |
| `DatabaseTaskMixin.getAllTasks()` | **不是死代码**——`data_export_page.dart:278` 通过 `DatabaseService.instance.getAllTasks()` 调用（数据导出功能）。SQL 为 `SELECT * FROM tasks ORDER BY cpl_time DESC`，**无 LIMIT**，导的是全量。见下方 X6 说明。 |
| `task_statistic_adapter.dart` 全部方法 | 全仓无调用方（统计埋点在 M1 范围外）。 |

#### ⚠️ 特例：`getRecycledTasks()` —— 同名两实现，**两个都是活代码**

`DatabaseTaskMixin` 与 `TaskRepositoryImpl` 各有一份同名方法，且**各自都有调用方**：

| 实现 | 调用方 | 用途 |
|---|---|---|
| `database_task_mixin.dart:257`（经 `DatabaseService.instance`） | `lib/modules/profile/pages/data_export_page.dart:300` | 数据导出页「导出回收站」开关 |
| `task_repository.dart:396`（经 `_taskRepository`） | `lib/providers/mixins/task_provider_core_mixin.dart:100` | Provider 加载回收站列表（`_loadRecycledTasks`） |

**两个实现的 SQL 与返回结构完全相同**，逐字一致：

```dart
// 两处都是这两行，只差 `database` / `_db` 的来源
final result = await db.query('recycled_tasks', orderBy: 'deleted_at DESC');
return result.map((m) => RecycledTask.fromMap(m)).toList();
```

`RecycledTask.toMap()` 输出 **15 列**（`task_model.dart:153-171`：`id`、`task_id`、`loop_id`、`title`、`description`、`is_word`、`is_ok`、`cpl_time`、`recurrence`、`completed_at`、`reward_points`、`is_deducted`、`created_at`、`priority`、`deleted_at`）。数据导出拿到的是**全 15 列**，不是任何子集。

**RN 实现要求**：只需实现一份等价逻辑（返回 15 列、按 `deleted_at DESC`、无 LIMIT）供回收站页使用。
**⚠️ 但不要直接复用它去做「数据导出」**——Flutter 侧导出走的是 `DatabaseService` 那一份，且导出功能整体在 M1 范围外。若将来做导出，必须单独确认每张表的导出字段白名单（各页面的 `_include*` 开关只控制部分表，`recycled_tasks` 那组还额外依赖 `toMap()` 的快照语义）。

---

## 1. 数据模型

### 1.1 `Task`（`tasks` 表）

| Dart 字段 | 列名 | 类型 | 构造默认值 | 备注 |
|---|---|---|---|---|
| `id` | `id` | INTEGER? | `null` | `toMap()` **不含 id**（insert 交给 SQLite 自增） |
| `loopId` | `loop_id` | TEXT? | `null` | 循环系列 id |
| `title` | `title` | TEXT | 必填 | 空串会被 Repository 抛 `ArgumentError` |
| `description` | `description` | TEXT? | `null` | 表单空串 → `null` |
| `isWord` | `is_word` | INTEGER | `0` | 「单词任务」 |
| `isOK` | `is_ok` | INTEGER | `0` | |
| `cplTime` | `cpl_time` | TEXT | **必填** | ISO8601 本地字符串 |
| `recurrence` | `recurrence` | TEXT | `'none'` | 枚举见下 |
| `completedAt` | `completed_at` | TEXT? | `null` | |
| `rewardPoints` | `reward_points` | INTEGER | `0` | |
| `isDeducted` | `is_deducted` | INTEGER | `0` | 逾期扣分幂等标记 |
| `createdAt` | `created_at` | TEXT | `DateTime.now()` | **注意：表单编辑时不传此参数 → 编辑会重置 `created_at` 为当前时间**，见 §6.2 b |
| `priority` | `priority` | TEXT | `'white'` | |

**枚举（严格三选，不许自造）：**
- `recurrence`：`none` | `daily` | `weekly` | `monthly`（**无 `yearly`**）
- `priority`：`red`(0) | `orange`(1) | `yellow`(2) | `blue`(3) | `white`(4)
  排序权重 `priorityOrder` 即上列序号；`priorityColor` 映射 red/orange/yellow/blue/`white→grey`。

### 1.2 `RecycledTask`（`recycled_tasks` 表）

与 `tasks` **同构**（含 `loop_id`），额外两列：

| 列 | 语义 |
|---|---|
| `task_id` | 原 `tasks.id`，**仅参考**。恢复时不用它当主键（见 §2.6） |
| `deleted_at` | 删除时间，ISO8601 本地 |

`recycled_tasks.id` 是**回收站自己的自增主键**，与 `task_id` 无关。UI 上所有「恢复/彻底删除」操作用的都是 `recycled_tasks.id`。

> 🔴 **`recycled_tasks.id` ≠ `task_id` —— 两者是不同含义的列，用错即数据损坏。**

| 列 | 含义 | 何时产生 | 谁用它 |
|---|---|---|---|
| `recycled_tasks.id` | **回收站自己的自增主键** | 移入回收站时由 SQLite 新分配 | **所有 UI 操作**（恢复 / 彻底删除 / 单条删除）传的都是它 |
| `recycled_tasks.task_id` | **原 `tasks.id`** | 从被删任务原样复制 | 仅供追溯与 H1 恢复时写回原 id |

**金样本实测**（`.spike-tmp/after.db` / `cur.db` / `seed.db` 三个库内容一致）：

```sql
SELECT id, task_id FROM recycled_tasks ORDER BY id;
-- id=1 → task_id=5
-- id=2 → task_id=99      ← 两行全不相等
```

**这是最直观的反证：同一个库、同一次查询，`id` 与 `task_id` 完全不是一回事。** 金样本数据由 team-lead 实测提供，我已复核三个库结果一致。

**关键约束**：
- 回收站卡片的点击、删除、清空，**全部用 `recycled_tasks.id`**，不是 `task_id`。
- 恢复时写回 `task_id`（H1 裁决）；若误用 `id` 当原任务 id 写回，会把任务恢复到**错误的 id**，导致 `points_records.related_id` 与 `task_tags.task_id` 指向别人的数据。
- `task_id` 可为 `NULL`（列可空，历史脏数据），此时 RN 侧走自增插入并打警告日志（U1 裁决）。

**正确 SQL 形态**（V1 裁剪，**顺序不可换**：先读出被裁剪行的 `task_id`，删完 `task_tags` 才能删 `recycled_tasks`）：

```sql
SELECT id, task_id FROM recycled_tasks ORDER BY deleted_at DESC;  -- ① 取 task_id，不是 id
DELETE FROM task_tags WHERE task_id = ?;                          -- ② 先清关联
DELETE FROM recycled_tasks WHERE id = ?;                          -- ③ 再删回收站行
```

**Flutter 侧对照**：`TaskProvider` 的 `_recycledTasks` 列表、回收站页的 `recycledTask.id` 全部是 `recycled_tasks.id`；只有 `repository.restoreTaskFromRecycle()` 内部读 `task_id`。

> ✅ **已修正**（由 team-lead 统一处理）：`rn/src/repo/types.ts` 的 `RecycledTaskRow` 现为 `deleted_at` + `task_id`。
> 早期版本把 `deleted_at` 写成 `recycled_at` 且缺 `task_id`——**H1 修复依赖 `task_id`**，缺它则无法写回原 id。

---

## 2. 数据读写（A 节）

> RN 注意：以下所有 SQL 均为**同步读**（`db.executeSync`）。写操作用 `writeBatch()` / `db.executeBatch()`，**事务内禁止混用 `executeSync`**（见 `rn/src/repo/base.ts:56`）。
> 所有时间参数均用 `isoMinute()` 或 `nowLocalIso()` 生成，**不要用 `new Date().toISOString()`**（那是 UTC）。

### 2.1 `getTasksForDate(date)` — 首页/日历的主查询

```sql
SELECT * FROM tasks
WHERE cpl_time >= ? AND cpl_time < ?     -- [当日 00:00, 次日 00:00)
ORDER BY is_ok ASC,
         CASE priority WHEN 'red' THEN 0 WHEN 'orange' THEN 1
                       WHEN 'yellow' THEN 2 WHEN 'blue' THEN 3
                       WHEN 'white' THEN 4 END,
         cpl_time ASC,
         id DESC;
```

- 参数用 `isoMinute(Date(y,m,d))` 与 `isoMinute(Date(y,m,d+1))`。
- **无 LIMIT**。一整天全部返回。
- 排序含义：未完成在前 → 优先级高在前 → 计划时间早在前 → 同时间新 id 在前（`id DESC` 即后插入的在前）。
- 这条 `ORDER BY` 是**唯一的「默认排序」**。`TaskSortOption.defaultOrder` 不做任何二次排序（见 §2.9）。

### 2.2 `searchTasks(...)` — 菜单面板搜索 / 高级搜索

```sql
SELECT * FROM tasks
WHERE (title LIKE ? OR description LIKE ?)   -- 仅当 query 非空，参数 '%q%'
  AND cpl_time >= ?                          -- startDate（若给）
  AND cpl_time < ?                           -- endDate 归一化到当日 00:00 + 1 天（若给）
  AND is_ok = ?                              -- completionStatus（若给，true→1/false→0）
ORDER BY created_at DESC
LIMIT 50 OFFSET 0;
```

- **默认 `limit = 50`，UI 永不传别的值、不分页**。`offset` 参数存在但恒为 0。
- `description LIKE` 在 `description IS NULL` 时不匹配（Dart `LIKE` 对 NULL 得 NULL → 不成立）。这是既有行为。
- `endDate` 会被 `DateTime(y,m,d).add(1 day)` 归一化 → **含当天整天**。
- `startDate` **不归一化**，直接用传入值的 ISO 串。UI 传入的三框日期是 `DateTime(y,m,d)`（00:00），所以实际等价于当日 00:00 起。

### 2.3 `getTasksByDateRange(start, end)` — 月视图 / 统计

```sql
SELECT * FROM tasks
WHERE cpl_time >= ? AND cpl_time < ?
ORDER BY cpl_time DESC;
```
无 LIMIT。仅被 `TaskProvider.getTasksForMonth()` 调用（§2.8）。

### 2.4 `getRecurringTasks()`

```sql
SELECT * FROM tasks WHERE recurrence != 'none';
```
**无 ORDER BY、无 LIMIT、无去重**。全库循环任务一次性捞进内存（含所有 loop 的全部实例），随后在 Dart 里归并模板。

### 2.5 `getTasksByLoopId(loopId)`

```sql
SELECT * FROM tasks WHERE loop_id = ?;
```
无 ORDER BY。返回该系列**全部实例**（含过去的）。被 `updateTask(updateAll:true)` 与 `deleteTask(deleteAll:true)` 依赖。

### 2.6 `getRecycledTasks()`

> ⚠️ **运行时路径 = `task_repository.dart:396 getRecycledTasks()`**（被 `task_provider_core_mixin.dart:100` 调用）。
> mixin 版（`:257`）只被数据导出页调用，两者 SQL 相同。

```sql
SELECT * FROM recycled_tasks ORDER BY deleted_at DESC;
```
**无 LIMIT**（实际上限由写入时的清理逻辑保证 ≤ 10，见 §3.7）。

### 2.7 逾期查询 `getOverdueTasks(date)`

```sql
SELECT * FROM tasks
WHERE cpl_time < ?      -- ⚠️ 变量名叫 endOfDay，实际值是 Date(y,m,d) 当日 00:00
  AND is_ok = 0
  AND is_deducted = 0
  AND recurrence = 'none';   -- ⚠️ 循环任务永不逾期扣分
```

- **第三个坑**：条件是 `cpl_time < 当天 00:00`，即**只处理昨天及更早**的任务。今天凌晨 0 点到现在的任务不算逾期。
- **第四个坑**：`recurrence = 'none'` 硬编码在 SQL 里 → **循环任务实例永远不会被扣逾期分**，哪怕过期一年。

### 2.8 `insertTaskIfNotExists(task)` — 插入前的重复检测

插入前必做一次存在性检查（SQL 下推，非全表扫描）：

```
if (task.recurrence != 'none' AND task.loop_id IS NOT NULL)
    → _existsInLoop(loop_id, cplTime)
else
    → _existsTaskOnDate(title, description, cplTime)
```

**分支 A（循环任务）**
```sql
SELECT id FROM tasks
WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ?
LIMIT 1;
```

**分支 B（非循环，或循环但 loop_id 为空）**
```sql
SELECT id FROM tasks
WHERE title = ? AND cpl_time >= ? AND cpl_time < ?
  AND (description IS NULL)          -- description 为 null 时
  -- 或 description = ?               -- description 非 null 时
LIMIT 1;
```

**命中重复时的行为：静默跳过插入，`addTask()` 返回传入的那个 Task（`id == null`）。**
调用方 `TaskProvider.addTask()` 仍会继续走后续流程（生成循环实例、刷新列表），但**新建表单的 `_createTask` 会因 `createdTask.id == null` 而跳过打标签**。UI 不弹任何提示 → 用户以为添加成功了，实际没有。**这是既有行为，1:1 复刻，不要"修好它"。**

### 2.9 筛选与排序：三层叠加

**第一层 SQL**：`getTasksForDate` 的 `ORDER BY`（§2.1）。
**第二层 Dart 内存筛选**：`TaskSortUtils.applyAllFilters()`，**严格按此顺序**：

```
1. filterByTagIds(result, filteredTaskIds)   -- 仅当 selectedTagId != null
2. filterByPriority(result, priorityFilter)   -- 仅当 priorityFilter != null
3. filterByCompletion(result, completionFilter)
4. filterByRecurrence(result, recurrenceFilter)
5. filterBySearchQuery(result, searchQuery)   -- 恒为空，见 §6.2
6. sortTasks(result, sortOption)
```

注意 1 和 2–4 的语义完全不同：

| 筛选项 | 类型 | 语义 | 空值行为 |
|---|---|---|---|
| 标签 | `_filteredTaskIds: List<int>` | **白名单**：`tasks.where(t => tagIds.contains(t.id))` | **`tagIds.isEmpty` → 直接返回空列表**（不是不过滤！） |
| 优先级 | `String?` | `t.priority == value` | null → 不过滤 |
| 完成状态 | `bool?` | `t.isOK == value` | null → 不过滤 |
| 任务类型 | `bool?` | true → `recurrence != 'none'`；false → `recurrence == 'none'` | null → 不过滤 |
| 搜索词 | `String` | title/description 小写 contains | 空串 → 不过滤 |

`sortTasks` 五种模式：

| TaskSortOption | 中文标签 | 比较逻辑 |
|---|---|---|
| `defaultOrder` | 默认排序 | **不做任何事**（保留 SQL 顺序） |
| `priority` | 按优先级 | `a.priorityOrder - b.priorityOrder` 升序 |
| `completionStatus` | 按完成状态 | `isOK` 升序（未完成在前）；相等返回 0 |
| `createdTime` | 按创建时间 | `createdAt` **降序** |
| `completionTime` | 按完成时间 | 非空在前；两组都空 → 按 `createdAt` 降序；否则 `completedAt` **降序** |

> ⚠️ Dart 的 `List.sort` **不稳定**。同 key 的相对顺序在 Dart 里是实现细节。RN 的 `Array.prototype.sort` 在 ES2019+ 起是**稳定排序**。这会造成同 key 项的顺序差异——通常无害，但如果要像素级一致，需显式加 `id` 作为 tiebreaker。（推荐加，稳定排序总比不稳定可预测。）

**第三层 Tab 过滤**（`TaskPage._getFilteredTasks`，与上面的 `recurrenceFilter` 独立）：

| Tab index | 标签 | 过滤 |
|---|---|---|
| 0 | 全部 | 不过滤 |
| 1 | 普通 | `recurrence == 'none'` |
| 2 | 循环 | `recurrence != 'none'` |

> **Tab 过滤与「任务类型」筛选器是两个独立机制，可叠加。** 空态文案也不同：Tab 2 空 → 「暂无循环任务」。

### 2.10 加载上限与缓存

| 项 | 值 | 位置 |
|---|---|---|
| 单日列表 | **无上限** | §2.1 |
| 搜索结果 | **硬编码 50** | §2.2 |
| 回收站 | **保留最近 10 条** | §3.7 |
| 桌面小组件 | **取前 5 条** `.take(5)` | `task_widget_mixin.dart:34` |
| 积分流水 | 每次刷新 `LIMIT 50`，`created_at DESC` | `database_points_mixin.dart:120` |
| 月份缓存 | **LRU，最多 3 个月**，key = `"$year-$month"` | `task_provider_core_mixin.dart:74` |

月份 LRU 的实现细节（RN 需复刻）：命中时先 `remove(key)` 再 `set(key)`（利用 Map 插入序把该月移到队尾 = 最近使用）；未命中且 `length >= 3` 时删 `keys.first`（最久未用）再写入。

失效规则：
- `addTask` / `completeTask` / `uncompleteTask` / `updateTask` / `restoreTaskFromRecycle` → 只失效**该任务 `cplTime` 所在月**。
- `deleteTask` → **`_tasksByMonthCache.clear()` 清空全部**（因为循环任务批量删除会跨月）。

---

## 3. 状态流转与副作用（B 节）

### 3.1 创建任务

**入口有 3 条**，字段默认值差异很大：

#### 入口 1：首页 FAB → 完整表单（`TaskFormWidget`，ModalBottomSheet）

表单初始值（新建时）：
```
title      = ''
description= ''
points     = '0'                      -- 字符串，提交时 int.tryParse，失败 → 0
date       = taskProvider.selectedDate  ← 注意是「当前选中日期」，不是今天
recurrence = 'none'
priority   = 'white'
isWord     = false
tags       = {}                        -- 空集合
```

提交时构造：
```
title        = 输入框 .trim()；空 → SnackBar「请输入任务名称」并 return（不写库）
description  = 输入框 .trim()；空串 → null
cplTime      = _selectedDate（DateTime 原样，含时分秒！）
rewardPoints = int.tryParse(points) ?? 0     -- 负数可输入，无校验
recurrence   = 下拉框
priority     = 五色圆点
isWord       = 由「单词」标签是否选中推导（见下）
```

**字段可见性由设置决定**（`_shouldShowField`）：
- `taskCreateMode == full` → 全显示
- `== minimal` → 全不显示（但此模式下首页走入口 2，不会到这里）
- `== custom` → 逐字段查 `settings.isFieldEnabled(key)`，key ∈ `description | rewardPoints | date | recurrence | priority | isWord`
  - 默认全开，**`isWord` 默认关**（`TaskCreateFields.isWord.defaultEnabled = false`）

**`isWord` 与「单词」标签的联动**（`TaskTagFieldWidget`）：
- 若 `tags` 表为空（不可能——`TagProvider.initialize` 会建 4 个默认标签）→ 显示单个「单词任务」勾选行。
- 正常路径：渲染全部标签的 FilterChip。**每次勾选变化时，`isWord = (wordTagId != null && next.contains(wordTagId))`**。即 `is_word` 列不是独立开关，而是「是否勾选了名为『单词』的系统标签」的派生值。
- 若用户手动改了勾选，**`task_tags` 也会被写入**（见下），所以两者天然一致。

写入顺序（`task_form_submit_mixin._createTask`）：
```dart
createdTask = await taskProvider.addTask(task);      // ① 写 tasks 表
if (_selectedTagIds.isNotEmpty && createdTask.id != null)
    await tagProvider.setTagsForTask(createdTask.id, ids);  // ② 写 task_tags
Navigator.pop();
```
⚠️ ①②**不在同一事务**。且 `setTagsForTask` 是「先 `DELETE task_tags WHERE task_id=?` 再逐条 INSERT」（`tag_provider.dart:70`），非事务。

#### 入口 2：首页 FAB → 快速添加对话框（`taskCreateMode == minimal`）

`AlertDialog`，**只有一个标题输入框**，`autofocus: true`，回车即提交。

```dart
final task = Task(title: title, cplTime: taskProvider.selectedDate);
// → 其余全部走构造默认值：isWord=false, isOK=false, recurrence='none',
//   completedAt=null, rewardPoints=0, isDeducted=false, createdAt=now, priority='white'
taskProvider.addTask(task);   // ⚠️ 未 await，直接 pop
```
标签为空 → `task_tags` 不写。
⚠️ 空标题：SnackBar「请输入任务名称」，对话框**不关闭**。

#### 入口 3：编辑已有任务（长按卡片 / 富卡片编辑按钮）

`TaskFormWidget.show(task: existing)`。**前置门禁**：若任务非今天 且 `settings.allowEditPastTasks == false` → SnackBar「非当天任务无法编辑，可在设置中开启」并**直接 return，不打开表单**。

提交时与新建的差异：
```dart
isOK        = widget.task?.isOK ?? false       // 保留
completedAt = widget.task?.completedAt         // 保留
isDeducted  = widget.task?.isDeducted ?? false  // 保留
loopId      = widget.task?.loopId              // 保留
// ⚠️ createdAt 未传 → 构造器默认 DateTime.now() → 编辑会重置 created_at
```

**保存前先写标签**（`_updateTask` 第一件事就是 `setTagsForTask`），**再更新任务**。

#### `TaskProvider.addTask()` 的完整副作用链

```dart
1. 若 recurrence != 'none' 且 loopId == null → loopId = generateLoopId()
     格式：'loop_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}'
2. createdTask = await repository.addTask(taskToAdd)
     └ 内部：重复检测（§2.8）→ INSERT tasks
3. _invalidateMonthCache(task.cplTime)          // 失效该月
4. 若 recurrence != 'none' → generateRecurringTasks(taskToAdd)   // §4
5. await loadTasksByDate(task.cplTime)         // ⚠️ 切到该任务所在日期并重载
6. return createdTask
```

> **第 5 步是重要副作用**：在「未来日期」创建任务后，首页会自动跳到那一天。删除/编辑同理（见 §3.4、§3.6）。

### 3.2 完成任务

**入口**：`TaskPage._onTaskCheckChanged(true)`；批量完成；桌面小组件同步。

**门禁（仅 UI 层，Provider 层无门禁）**：
```dart
isToday = task.cplTime 的 y/m/d == now 的 y/m/d
if (!isToday && !settings.allowCompletePastTasks)
    → 居中红条 toast「非当天任务无法完成，可在设置中开启高级模式」(3 秒)，return
if (_lastWarningTime != null && now.difference(_lastWarningTime).inSeconds < 3) return;
    // ⚠️ 死代码：_lastWarningTime 只在 completeTask 返回非 null 时赋值，
    //    而 completeTask 恒返回 null（repository 实现），故此分支永不触发
```

**写入（Repository）**：
```sql
UPDATE tasks SET is_ok = 1, completed_at = <nowLocalIso()> WHERE id = ?;
```
返回 `null`（**签名是 `Future<String?>` 但永远返回 null**，UI 的 `warn` 分支是死路）。

**结算副作用**（`TaskSettlementMixin._settleTaskCompleted`）：
```
若 task.id == null 或 task.rewardPoints <= 0 → 直接返回，不写流水
latest = SELECT * FROM points_records
        WHERE related_id = task.id AND type IN ('task_complete','task_uncomplete')
        ORDER BY id DESC LIMIT 1
若 latest?.type == 'task_complete' → 直接返回（不加分）

否则事务内：
  UPDATE user_points SET points = points + rewardPoints, updated_at = <now>
    WHERE id = 1;
  INSERT INTO points_records(points, type, description, related_id, created_at)
    VALUES (rewardPoints, 'task_complete', '完成任务: <title>', task.id, <now>);
```

**⚠️ 关键：`completed_at` 写的是 `DateTime.now()`（真实时刻），不是任务的 `cplTime`。** 与 `cplTime` 可以差很远（补做昨天任务 → `completed_at` 是今天）。

**UI 反馈**：`rewardPoints > 0` → 黑底 toast「获得 +N 积分！」(1 秒)。

**循环任务副作用：完成时**不**生成下一批实例。** 生成只发生在「创建」「编辑」「应用启动」三个时机（§4.1）。** 这一点反直觉，务必不要在 RN 里改成「完成即生成」。

**小组件同步**（`syncFromWidget`，App 生命周期 `resumed` 时）：读小组件缓存的任务列表，按 **task id 精确匹配**（不是列表下标），若 `isOK` 与本地不同则调 `completeTask`/`uncompleteTask`，description 前缀改为 `'完成任务(小组件): '` / `'取消完成(小组件): '`。整个方法包在 try/catch 里，失败只 `AppLogger.warn`。

### 3.3 取消完成

**门禁**：同 §3.2，且文案换成「非当天任务无法取消完成，可在设置中开启高级模式」。

**写入**：
```sql
UPDATE tasks SET is_ok = 0, completed_at = NULL WHERE id = ?;
```

**结算副作用**（`_settleTaskUncompleted`）—— **本模块最容易写错的地方**：
```
latest = SELECT * FROM points_records
        WHERE related_id = task.id AND type IN ('task_complete','task_uncomplete')
        ORDER BY id DESC LIMIT 1
若 latest == null 或 latest.type != 'task_complete' → 直接返回，不写流水

否则事务内：
  UPDATE user_points SET points = points - latest.points, updated_at = <now> WHERE id = 1;
  INSERT INTO points_records(points, type, description, related_id, created_at)
    VALUES (-latest.points, 'task_uncomplete', '取消完成: <title>', task.id, <now>);
```

> **金额取 `latest.points`（历史流水的值），不是任务当前的 `rewardPoints`。**
> 场景：任务完成时给了 10 分 → 用户把奖励改成 20 → 再取消完成。**只扣 10 分**，账目对称。RN 直接复用 `resolveUncompletion({latestSettlementType, latestSettlementPoints})`。

**UI 反馈**：`rewardPoints > 0` → 红条 toast「扣除 N 积分」——⚠️ **这里用的是任务当前的 `rewardPoints`，与实际扣减额可能不一致**（见 §6.2 c）。既有行为，照抄。

**积分可负**：`applyPointsChange` 未传 `requireAtLeast`，所以 `UPDATE` 无 `points >= ?` 条件 → **余额允许为负**。这一条回答了 `business-rules.md` §6 待核实第 1 项：**代码允许负余额，RN 不要加拦截**。

### 3.4 编辑任务

**写入（Repository，单条）**：
```sql
UPDATE tasks SET loop_id=?, title=?, description=?, is_word=?, is_ok=?, cpl_time=?,
                recurrence=?, completed_at=?, reward_points=?, is_deducted=?,
                created_at=?, priority=?      -- ⚠️ 全列覆盖，toMap() 不含 id
WHERE id = ?;
```
> `Task.toMap()` 返回**除 id 外的全部 12 列**，`db.update` 因此是全列覆盖。任何 `copyWith` 漏掉的字段都会被原值保留（因为 `??` 兜底），但 `completedAt` 有一个陷阱：`copyWith(completedAt: null)` **无法把 completedAt 置空**（`null ?? this.completedAt` 走 else 分支）。现有代码里没有依赖这个行为的路径，RN 侧实现 `copyWith` 等价物时要意识到这个语义差异。

**`updateAll = true` 的联动更新**（仅当 `task.recurrence != 'none' && loopId != null`）：

触发条件（`_updateTask`）——**只有这 6 个字段变化时才弹确认框**：
```
title, description, isWord, rewardPoints, priority, recurrence
```
**`cpl_time` 变化不触发！** 所以改日期不会弹「是否更新所有未来的循环任务？」。

对话框：「更新循环任务 / 是否更新所有未来的循环任务？」→ `仅此任务` | `全部更新`。

选择「全部更新」后的实际逻辑（`repository.updateTask`）：
```dart
tasksToUpdate = SELECT * FROM tasks WHERE loop_id = ?;
for (t in tasksToUpdate) {
    if (t.id == task.id) continue;
    if (isDateBefore(t.cplTime, task.cplTime)) continue;   // 只改「不早于本任务」的实例
    UPDATE tasks SET <title, description, is_word, reward_points, priority, recurrence 来自新 task>
    WHERE id = t.id;
}
```
- `isDateBefore(a, b)` 只比较 **y/m/d**（各自归零时分秒）。
- 联动的字段**只有 6 个**：`title / description / isWord / rewardPoints / priority / recurrence`。**不含 `cpl_time`**——所以「全部更新」不会移动其他实例的日期。
- 逐条 `UPDATE`，**不在事务里**（中途失败 → 部分更新）。
- **过期实例（早于本任务的）永远不会被联动修改**，它们的旧 title/积分会永久留存。

**改 `cpl_time` 对循环任务的影响**（`TaskProvider.updateTask`）：
```dart
await repository.updateTask(task, updateAll: updateAll);
_invalidateMonthCache(task.cplTime);
if (task.recurrence != 'none') await generateRecurringTasks(task);   // ⚠️ 用的是「新的」cplTime
await loadTasksByDate(task.cplTime);   // ⚠️ 跳到新日期
```
→ 改日期后，生成器以**新日期**为起点重跑 §4，会把新日期起到 `now+15d` 的实例补齐。**旧日期的已有实例不会被删除或搬移。**

### 3.5 逾期判定与扣分

> **回答「逾期是查询时算的还是定时任务写库的」：**
> **都不是「定时任务」。是「应用启动时跑一次的显式检查」，且只有一条数据写入（`is_deducted`）。逾期状态本身从不被物化成任何列。**
> 所谓「逾期」永远是**查询时用 `cpl_time` 与当前时间比较**得出的。

**触发时机**：**仅** `TaskProvider.initialize()`，即 `TasksHomePage._initializeProviders()` 首次构建时（每次冷启动首页时一次）。
```dart
Future<void> initialize() async {
  await WidgetService.init();
  await _loadRecycledTasks();
  await _checkOverdueTasks();            // ← 逾期扣分，唯一触发点
  await loadTasksByDate(DateTime.now());
  await autoCheckRecurringTasks();       // ← 循环生成，另一处
  _debouncedUpdateWidget();
}
```
**没有定时器、没有 WorkManager、没有 `resumed` 时重跑。** App 长时间挂在后台跨过午夜，**不会**触发扣分；必须冷启动。

**执行流程**（`_checkOverdueTasks`）：
```dart
overdueTasks = getOverdueTasks(DateTime.now());   // §2.7，SQL 已过滤 is_ok=0/is_deducted=0/recurrence='none'
for (task in overdueTasks) {
    if (task.id == null || task.isOK || task.isDeducted) continue;   // 二次防御
    if (task.rewardPoints <= 0) continue;

    deductPoints = (rewardPoints / 2).floor();
    if (deductPoints > 0 && !hasRecord('overdue_deduct', task.id)) {
        事务内：
          UPDATE user_points SET points = points - deductPoints, updated_at = <now> WHERE id = 1;
          INSERT INTO points_records(...)
            VALUES (-deductPoints, 'overdue_deduct', '逾期任务扣除: <title>', task.id, <now>);
    }
    await catchUpOverdueDeduction(task.id);   // ← 无条件执行，见下（RN 侧改名，见下条）
}
```

**⚠️ RN 侧命名要求：`markTaskDeducted` → `catchUpOverdueDeduction`。**
Flutter 侧原名 `markTaskDeducted`（`task_repository.dart:326`）**与行为相反**：它不是「打标记」，而是**补扣**——把之前因各种原因没扣成的 `floor(rewardPoints/2)` 真正扣掉（幂等保护，见下条 2）。**裁定：RN 侧改名 `catchUpOverdueDeduction`，纯重命名、零行为变化**，属可读性修复。本文档其余章节仍用 Flutter 原名以便对照，实现时统一用新名。

**`is_deducted` 在哪一步被置位 —— 三个必须知道的细节：**

1. **顺序（红线，已遵守）**：先扣分成功，再 `UPDATE tasks SET is_deducted = 1`。注释明确说明反过来的后果是「永久漏扣」。
2. **⚠️ `markTaskDeducted`（RN: `catchUpOverdueDeduction`）在 `if` 之外，无条件执行。** 即使 `deductPoints == 0`（如 `rewardPoints == 1` → `floor(0.5) == 0`）或已存在 `overdue_deduct` 流水（跳过扣分），**`is_deducted` 仍会被置 1**。效果：该任务此后不再进入逾期候选集（SQL 的 `is_deducted = 0` 会滤掉）。既有行为，照抄。
3. `is_deducted` **永不复位**。任务被取消完成后 `is_deducted` 保持原值。

**幂等是「双门 AND」，不是「或」** —— 这一点必须理解准确，否则会误判漏洞：

| 门 | 位置 | 作用 |
|---|---|---|
| 门 1 | `getOverdueTasks` 的 `WHERE is_deducted = 0`（`task_repository.dart:252`） | 列级标记 |
| 门 2 | `_shouldHandlePoints(task, 'overdue_deduct')` → `hasPointsRecordByTypeAndRelatedId`（`task_settlement_mixin.dart:13`） | 流水级查重（`WHERE type=? AND related_id=?`，只看「有没有过」） |

**只有两道门同时打开才会扣款。** 门 2 单独失效**不构成**重复扣款——门 1 仍会挡住。

**⇒ Flutter 现状下不存在重复扣款。** 已核实全仓 12 处 `isDeducted` 写入点：

| 路径 | `is_deducted` 行为 |
|---|---|
| 编辑任务（`task_form_submit_mixin.dart:28`） | `isDeducted: widget.task?.isDeducted ?? false` → **显式继承，不重置** ✅ |
| 恢复任务（`task_repository.dart:361`） | `(recycledMap['is_deducted'] ?? 0) == 1` → 从回收站行还原 ✅ |
| 循环实例生成 | `copyWith(isDeducted: false)`，但 `recurrence != 'none'` 被逾期 SQL 的 `recurrence = 'none'` 排除，进不了扣分循环 ✅ |

> ⚠️ 曾有一版裁决写「编辑表单不传 `isDeducted` → 构造默认值 `false` → 门 1 重新打开」，**该推论不成立**：表单在 `task_form_submit_mixin.dart:28` **显式传了**该字段；`task_model.dart:32` 的默认值只对**新建** Task 生效。（`m1-decisions.md` T1 已按此改写。）

#### 🔴 RN 实现红线（本文档唯一带 🔴 的约束）

> **实现 H1（恢复时写回原 `task_id`）时，绝不能顺手把 `is_deducted` 重置为 0。**
>
> 那一刻起：id 变更已让**门 2 失效**（`points_records` 的 `overdue_deduct` 流水按新 id 查不到，旧流水还挂在原 id 上）；
> 若 `is_deducted` 又被置 0，**门 1 同时失效** ⇒ **真扣用户积分、余额无下限保护**
> （`deductPointsWithRecord` 不传 `requireAtLeast`，`UPDATE` 只有 `WHERE id = 1`）。
>
> 这是**资金损失级红线的唯一触发路径**，且**只可能由 RN 实现引入**——Flutter 现状没有这条路径。
> 所以它不是「要修的缺陷」，是「实现时不能碰的约束」。

配套（`m1-decisions.md` U1）：保留原 id 后，**所有以该 id 为键的引用自动重新变有效**（`task_tags` 的行从没被删过，id 一回来关联就自动接回）。所以**正常路径不做任何引用改写**——`UPDATE ... SET task_id = 7 WHERE task_id = 7` 是空操作，误写成别的条件反而会把正确引用改错。
⚠️ **「主键冲突时降级为新 id 并改写 4 处引用」这条路径不存在**——冲突的处理是**整笔回滚并抛错**，**绝不降级**（见 §3.8）。实现者不要去写那段永远不会执行的代码。

#### 顺带记录一处不对称（既有行为，1:1 复刻即保留）

编辑任务时，同一个 `Task(...)` 构造调用里：

| 字段 | 是否显式传 | 结果 |
|---|---|---|
| `isDeducted` | ✅ 传了 `widget.task?.isDeducted ?? false` | **保留原值** |
| `createdAt` | ❌ **没传** → 构造器默认 `DateTime.now()` | **重置为当前时间** |

**一个刻意保留、一个意外重置。** 这是 §6.2 b（编辑重置 `created_at`）的成因，影响「按创建时间」排序与统计，**【照搬】RN 侧与 Flutter 侧一致**（照搬不改）。

**积分余额可为负**：同 §3.3，扣分无 `points >= ?` 条件。

### 3.6 删除任务

**入口与选项**：
| 任务类型 | 对话框选项 | `deleteAll` |
|---|---|---|
| `recurrence == 'none'` | 「确认删除 / 确定要删除这个任务吗？」 | `false` |
| `recurrence != 'none'` | 「确认删除 / 选择删除方式：」 | `false`（仅删除当天）/ `true`（删除全部） |

**`deleteAll = false` —— 移入回收站（软删除）**

**不是打标记，是整行搬走**。在**单个事务**内：
```sql
-- ① 先读源行
SELECT * FROM tasks WHERE id = ? LIMIT 1;
-- 若查不到 → 直接 return，什么都不做（静默成功）

-- ② 插入回收站（列对列复制 + 补两列）
INSERT INTO recycled_tasks(
  task_id, loop_id, title, description, is_word, is_ok, cpl_time,
  recurrence, completed_at, reward_points, is_deducted, created_at,
  priority, deleted_at)
VALUES (<源行 12 列原样>, <源行 id>, deleted_at = <nowLocalIso()>);

-- ③ 若上面 insert 成功（recycledId > 0）
DELETE FROM recycled_tasks WHERE id = <超出保留 10 条的那些>;   -- 见 §3.7
DELETE FROM tasks WHERE id = ?;
```

**两表字段差异（务必对齐）**：

| | `tasks` | `recycled_tasks` |
|---|---|---|
| 主键 | `id` = 自增 | `id` = **回收站自己的自增** |
| 原 id | — | `task_id`（仅参考，不保证还能对上） |
| `loop_id` | 有 | **有**（v3 才补，见下） |
| `deleted_at` | — | 有 |

**`loop_id` 在回收站里怎么存**：v2 之前 `recycled_tasks` **没有 `loop_id` 列**，导致循环任务恢复后丢失循环链。v3 迁移用幂等方式补上：
```sql
-- 检查
PRAGMA table_info(recycled_tasks);
-- 若无 loop_id 列则
ALTER TABLE recycled_tasks ADD COLUMN loop_id TEXT;
```
删除时 `loop_id` 从源行原样复制。**但注意：`DatabaseTaskMixin.moveTaskToRecycleBin()` 这个遗留方法不搬 `loop_id`**（测试已标注为已知行为）。运行时路径 `TaskRepositoryImpl.deleteTask()`（`task_repository.dart:163` 的 else 分支）**是搬的**。RN 实现走运行时路径即可。

**`deleteAll = true` —— 物理删除，循环任务专属**

⚠️ **不进回收站，不可恢复。**
```dart
tasksToDelete = SELECT * FROM tasks WHERE loop_id = ?;
filtered = tasksToDelete.where((t) => !isDateBefore(t.cplTime, task.cplTime));  // 保留不早于本任务的
if (filtered.isEmpty) return;
earliestTask = filtered.reduce((a,b) => a.cplTime.isBefore(b.cplTime) ? a : b);
DELETE FROM tasks WHERE id = earliestTask.id;         // 先删最早的那条
for (t in filtered) if (t.id != earliestTask.id) DELETE FROM tasks WHERE id = t.id;   // 再删其余
```
- `earliestTask` 那两行是**纯粹为了「先删最早」的多余编排**，最终效果等价于「逐条删除 `filtered` 全部」。RN 可直接简化为批量删除，但**删除顺序（最早优先）在 UI 动画上可能被观察到**，如需一致请保留。
- **不在事务内**。中途失败 → 部分删除。
- ⚠️ `filtered` 里包含**今天及以后**的实例。过去的不删。
- `deleteTask` 的 Provider 侧副作用：`_tasksByMonthCache.clear()`；**`deleteAll == true` 时不刷新回收站列表**（因为没进回收站）；`loadTasksByDate(_selectedDate)`；`_debouncedUpdateWidget()`。

**⚠️ 删除任务时**不立即**清理 `task_tags`——但该任务被永久删除时会清理。**

移入回收站（`deleteAll = false`）时**不立即**清理：该 `task_id` 的 `task_tags` 行要留着，
因为**恢复时id 写回原值（见 §3.8），关联会自动重新接回**（H1/H2/U1）。
若此时清掉，恢复后标签就真的丢了——**「标签自动接回」完全依赖这些行还在**。

清理挂在**任务被永久移出回收站的那一刻，与该删除同事务完成**（V1 + V1 补充）：

| 永久删除路径 | 同事务清理 |
|---|---|
| 回收站裁剪（移入第 11 个 → 最旧条目被物理删除） | ✅ 裁掉这批的 `task_tags` |
| 回收站内单条永久删除（`deleteFromRecycle`） | ✅ 该 `task_id` 的 `task_tags` |
| 清空回收站（`clearRecycleBin`） | ✅ 全部这批的 `task_tags` |
| **批量删除循环任务**（`deleteTask(deleteAll: true)`） | ✅ 这批实例的 `task_tags` |

> ⚠️ **批量删除循环任务**这一条是 **V1 补充**才发现的——初版漏了它，
> 漏了则「孤儿数恒为 0」不成立。实现时勿遗漏。
> ⚠️ 另：Flutter 的批量删除是**循环 `await db.delete(...)`、不在事务里**
> （`task_repository.dart:158-162`），中途失败会留下「删了一半」的循环链。
> **M1 修**：包进事务，与 `task_tags` 清理原子完成（原子性修复，非行为变更）。

⇒ **孤儿的生命周期从「永久」缩短为「0」**（V3 措辞）：不是「不产生孤儿」，而是「孤儿不存活」。
`schema-v3.md` §7 的「孤儿数为 0」在**迁移时点与运行期同时成立**，两套口径不再需要区分时序。

**🔴 V6（🔴 级，实现前必读）：清理条件一律用 `task_id`，永不用 `recycled_tasks.id`。**
两者是不同东西：`task_tags.task_id` 关联的是**原任务 id**（`recycled_tasks.task_id`），
而 `recycled_tasks.id` 是**回收站自己的自增主键**。金样本实测两者**全不相等**
（`id=1 → task_id=5`、`id=2 → task_id=99`，而 `tasks` 表里 id=1、2 都是**活着的任务**）。
拿错会导致**活任务的标签关联被静默删除**。详见 `m1-decisions.md` V6。

**这是 `task_tags` 孤儿行的唯一产生源，且是不对称的**：删**标签**时 `TagProvider.deleteTag` 会调 `deleteTaskTagsByTagId` 清理（`tag_provider.dart:54`）；删**任务**时**移入阶段**什么都不做、**永久删除阶段**才清（见上表）。
所以 `schema-v3.md` §5.4 猜的「可能有孤儿行」根因就在这一条路径上——不是历史迁移遗留。

> ⚠️ **`purgeOrphanTaskTags()` 保留为兜底，但不在启动时自动调用**（V1）。
> 它的用途已从「主清理机制」降级为「清理**历史遗留**脏数据」——旧库若在本次改动前
> 已积累孤儿（V1 之前不清理），需要靠它或 M2 的手动入口清一次。
> **运行时正常路径下不该有孤儿可清**，所以断言应是「孤儿数恒为 0」。
> ⚠️ 它有**两类**孤儿要分别处理、分别测试（V7）：`task_id` 维度（任务已不存在）
> 与 `tag_id` 维度（标签已删除，如金样本的 `8|999`）。不要混。

### 3.7 回收站上限：保留最近 10 条

在**删除事务内**执行：
```dart
rows = SELECT * FROM recycled_tasks ORDER BY deleted_at DESC;
if (rows.length > 10) {
    for (id in rows.skip(10).map((r) => r['id'])) {
        DELETE FROM recycled_tasks WHERE id = ?;
    }
}
```
逐条删除，非 `DELETE ... WHERE id NOT IN (...)`。**硬编码 10**，无设置项。

### 3.8 从回收站恢复

#### 非循环任务 / 「恢复循环」选项

**事务内**（`repository.restoreTaskFromRecycle` —— 运行时路径在 `task_repository.dart:361`，**不是** mixin 的 `:263`）：
```dart
row = SELECT * FROM recycled_tasks WHERE id = ?;
if (row.isEmpty) throw Exception('回收站任务不存在');

task = Task(
  loopId:     row.loop_id,          // ← v3 关键：恢复循环链
  title:      row.title,
  description: row.description,
  isWord:     row.is_word == 1,
  isOK:       row.is_ok == 1,       // ← 完成状态一并恢复
  cplTime:    parse(row.cpl_time),
  recurrence: row.recurrence ?? 'none',
  completedAt: row.completed_at != null ? parse(...) : null,
  rewardPoints: row.reward_points ?? 0,
  isDeducted: row.is_deducted == 1,  // ← 逾期标记一并恢复
  createdAt:  parse(row.created_at),   // ← 原创建时间保留（与编辑路径不同！）
  priority:   row.priority ?? 'white',
);
// ⚠️ 不传 id → INSERT 得全新 id（原 task_id 丢弃）

newId = INSERT INTO tasks (...12 列...);
DELETE FROM recycled_tasks WHERE id = ?;
return task.copyWith(id: newId);
```

**⚠️ 以下描述的是 Flutter 现状**（`id` 会变，且这个「变」会连带打断两个外键引用）——
已验证 `Task.toMap()` 不含 `id`（`task_model.dart:69-84`），所以 Flutter 侧恢复走的是自增新 id，`recycled_tasks.task_id` 被丢弃。
**⇒ RN 侧不照搬这一条**：按下方 🔧 裁决，**恢复时写回原 `task_id`**，不走自增、不丢 `task_id`。
（这一段与下方裁决相隔十几行，读到上面时若没看到下方，容易误以为 RN 也要走自增——所以在这里先标一句。）
后果：

| 引用方 | 指向 | 后果 |
|---|---|---|
| `task_tags.task_id` | 原 id | 行**从未被删过**（移入回收站不清理）→ id 写回原值后**自动重新指向真实任务，标签自动接回** ✅。`recycled_tasks` 无标签快照列，但**不需要**快照。 |
| `points_records.related_id` | 原 id | 同上，行从未被删 → id 写回后自动有效 ✅ |

**积分重复加分的完整路径**（与积分模块交叉，需两边对齐）：
1. 任务 A（id=7）已完成 → `points_records(related_id=7, type='task_complete', +10)`
2. 删除 A → `recycled_tasks(task_id=7, is_ok=1)`；`points_records` 的 `related_id=7` **仍在**（删任务不清理流水）
3. 恢复 A → 拿到新 id=42，`is_ok` **一并还原为 1**（`task_repository.dart:354`）
4. 用户再次完成 → `_settleTaskCompleted` 查 `related_id=42` 的最近流水 → **查不到**（流水在 7 上）→ 走「未加分」分支 → **再加 10 分**
5. 结果：同一个任务完成两次，积分加了两次。

> **🔧 裁决（M1，第二轮 QA 核查后修订）：改为「修」——恢复时写回原 id。** 本条原先写的是「照搬（id 会变），不修」，现已作废。
> 初版不修的理由是「与积分模块的 H1 是同一个根因，必须两边同时决策」。QA 独立核查确认这个前置条件已满足（积分与任务仓储由同一裁决统筹，M1 内可同步落地），且**不修的代价更大**：
> - 恢复后取消完成 → `getLatestRecord(新id)` 查不到 → **不冲销**，用户白留着分；
> - 恢复后再次完成 → 查不到 → **再加一次分**，余额凭空 +40。
>
> **修法与影响范围见下方「🔧 M1 裁决：两条恢复路径合并为同一个仓储方法」。** 附带说明：恢复时 `is_ok: row.is_ok == 1` 会**一并还原完成状态**，所以恢复后任务在 UI 上仍是勾选态，「直接再点完成」这条路径不存在；真实路径是「恢复 → 取消完成（冲销）→ 再次完成（加分）」，两个方向都正确。

**Provider 侧后续**（`TaskRecycleMixin.restoreTaskFromRecycle`）：
```dart
restoredTask = await repository.restoreTaskFromRecycle(id);   // → task_repository.dart:361（mixin :263 是死代码）
_invalidateMonthCache(原 cplTime);
if (restoredTask.recurrence != 'none')
    await generateRecurringTasks(restoredTask.copyWith(cplTime: 原cplTime));
await _loadRecycledTasks();
await loadTasksByDate(_selectedDate);
```
> `.copyWith(cplTime: originalCplTime)` 是**防御性冗余**——恢复出来的 `cplTime` 本就等于 `originalCplTime`。无害。

**恢复后标签自动接回**（🔧 H1 修后）：`task_tags` 的行从未随任务搬进回收站（移入时不清理，见 §3.6），
id 写回原 `task_id` 后这些行**自动重新指向真实任务**，无需任何 `UPDATE`（U1）。

> ⚠️ **V2 前提（别把这条读成「恢复必然带回标签」）**：自动接回成立需要**两个条件同时满足**——
> ① **H1 生效**（恢复时写回原 id）；② **该条目仍在回收站内**。
> ② 失效的情形：回收站上限 10 条，用户删到第 11 个时最旧条目被**裁剪**，
> 或用户**清空**回收站——此时该任务已被永久删除，其 `task_tags` 行按 V1 已同事务清掉，
> **恢复后标签不会回来**（因为已无关联行可接）。
> ⇒ 准确表述是「**在条目仍存活于回收站的前提下，恢复会自动带回标签**」，不是「恢复必然带回」。

⚠️ 这**完全依赖**「移入回收站时不清 `task_tags`」——若在移入时就清掉，恢复后标签真的就没了。

#### 「仅恢复当天」选项（循环任务专属）

**不走 `restoreTaskFromRecycle`**，而是：
```dart
newTask = task.copyWith(recurrence: 'none');   // 只降级为一次性
await taskProvider.deleteFromRecycle(recycledTask.id);   // 先删回收站行
await taskProvider.addTask(newTask);                      // 再走正常新建流程
```
**⚠️ 非原子**：两步。若第 2 步因重复检测（§2.8 分支 B，同标题+同描述+同天）被跳过 → **任务彻底丢失**（回收站已删、tasks 未插）。
**⚠️ `copyWith` 保留了原 `id`** → `addTask` → `INSERT` 时 `toMap()` 不含 id，所以不会冲突；但 `task.id` 在内存里是旧值，若后续逻辑误用会出错。RN 实现时注意丢弃 `id`。
**⚠️ 恢复了 `loopId`**（`copyWith` 不改它），所以这是一条「`recurrence='none'` 但 `loop_id` 非空」的历史脏数据。生成器不会碰它（`recurrence=='none'` 直接 break），但去重检测分支 A 会因为 `recurrence=='none'` 而**不**被触发（分支 A 要求 `recurrence != 'none'`），所以它会走分支 B。有既有风险，照抄。

##### 🔧 M1 裁决：两条恢复路径合并为同一个仓储方法（本节取代上面的「照搬」）

QA 独立核查发现：**上面这条「仅恢复当天」路径是 H1 刷分漏洞的绕过后门**——它走 `addTask`（`Task.toMap()` 不含 id）→ 拿全新自增 id → 原 `points_records` 引用同样悬空 → 重复加分/不冲销照样发生。用户只要点「仅恢复当天」就能绕过只修 `restoreTaskFromRecycle` 的补丁。

**因此 M1 裁定：两条路径合并为一个仓储方法，用参数区分「是否保留循环链」。**

| 要求 | 说明 |
|---|---|
| **单一入口** | `restoreTask(recycledTaskId, { bool keepRecurrenceChain })`。`keepRecurrenceChain=true` → 等价「恢复循环」；`false` → 等价「仅恢复当天」（`recurrence` 置 `'none'`）。UI 的两个按钮都调它，只是参数不同。 |
| **两条都保留原 id** | `INSERT INTO tasks (id, ...) VALUES (recycled_tasks.task_id, ...)`。**不得**依赖自增。 |
| **两条都在单事务内** | 插入 + 删除回收站行，一个事务。**顺带修掉现状「仅恢复当天」的非原子 delete+add**（上文那个「任务彻底丢失」窗口）。 |
| **`task_id` 为 NULL 时降级** | `recycled_tasks.task_id` 建表时**可空**（`database_schema_mixin.dart:82`，`schema-v3.md §2.2` 也标了 ✓）。为 NULL 时退回自增插入（新 id），此时引用无从修正——属无法恢复的旧数据，不阻断流程。 |

> **⚠️ 关键澄清：因为 id 写回原值，4 处引用「自动保持有效」，不需要写任何 `UPDATE`。**
> 这一条与早先的「同步修正引用」说法不同，以本条为准。
>
> 推理：`task_tags.task_id = 7`、`points_records.related_id = 7`、`pomodoro_records.related_task_id = 7` 这些行**从来没被删过**（删任务不清理它们）。任务恢复成 `id = 7` 之后，它们**重新指向了一个真实存在的任务**，关联自然接回去。
>
> 所以「恢复时改写引用」是**多余且危险**的操作：若照旧裁决去跑 `UPDATE points_records SET related_id = :new WHERE related_id = :old`，而 `:new` 就是 `:old`，则是无害的 no-op；但若实现时把 `task_id` 与「恢复后的 id」搞混（例如把 `:new` 算成自增值），这批`UPDATE` 会把原本正确的引用**改成错的**。
>
> **RN 实现要求**：只需写回原 id，**不要**加任何引用改写语句。主键冲突检查（见下）才是必须的那一环。
>
> 唯一需要`UPDATE` 的场景是**将来**若有人改成「新分配 id」的实现——那条路已被 H1 否决。

**主键冲突处理**：不能假设「原 id 在 `tasks` 中必然不存在」。`AUTOINCREMENT` 保证的是「自动分配时不复用已删除 id」，**不保证显式插入不冲突**——显式插入走主键约束，撞了就是 `UNIQUE constraint failed`。所以必须：
```sql
SELECT 1 FROM tasks WHERE id = :originalId;   -- 命中则说明有意外，必须回滚并提示
```
**绝不能静默换一个 id 分配**（那等于没修）。

> **⚠️ 循环链相关的既有脏数据仍照抄**：`keepRecurrenceChain=false` 时 `loop_id` **照搬保留**（U2 已裁决）。
> 为什么零影响：`getRecurringTasks()`（`task_repository.dart:236-243`）按 `WHERE recurrence != 'none'` 过滤，
> 所以「`recurrence='none'` + `loop_id` 非空」的脏行**永远不会被循环生成器取到**。
> 保留它是因为「仅恢复当天」的用户意图是「不要循环逻辑」，清空 `loop_id` 属行为变更，M1 不做。
> 参见上文「恢复了 `loopId`」那条分析。

#### 其它回收站操作

```sql
-- 彻底删除单条（无二次确认！）
DELETE FROM recycled_tasks WHERE id = ?;

-- 清空（先弹「确定要清空回收站吗？此操作不可恢复。」）
DELETE FROM recycled_tasks;
```

### 3.9 批量操作

进入批量模式：`菜单 → 批量操作`（切换 `_batchMode`），或 `BatchActionBar` 的关闭按钮退出。切换到 false 时清空 `_selectedTaskIds`。

选择：点卡片任意位置 → `toggleTaskSelection(task.id)`。「全选」= **选中当前 `_tasks` 全部**（未筛选、未 Tab 过滤的原始当日列表）的 id。
> 「全选」按钮的禁用条件是 `selectedTaskIds.length == rawTasks.length`——用的是 `rawTasks`（`_tasks`，未过滤），而实际可选范围是 `filteredTasks`（已过滤 + Tab）。**所以筛选态下「全选」按钮的禁用时机与直觉不符**，既有行为。

六个批量动作，**全部逐项执行，单项失败不影响其余**：

| 动作 | 前置条件 | 实际调用 |
|---|---|---|
| 批量完成 | `!task.isOK` | `completeTask(task)` |
| 批量取消完成 | `task.isOK` | `uncompleteTask(task)` |
| 批量删除 | — | `deleteTask(taskId)`（`deleteAll=false`，进回收站） |
| 批量改优先级 | — | `updateTask(task.copyWith(priority: p))` |
| 批量改日期 | — | `updateTask(task.copyWith(cplTime: date))` |
| 批量改标签 | — | `tagProvider.setTagsForTask(taskId, tagIds)` |

关键实现细节：
- **查任务用 `_taskByIdInList`（遍历 `_tasks` 线性查找，返回 null 则跳过）**，**不用 `firstWhere`**。原因：`firstWhere` 找不到会抛 `StateError` 中断整批。已删/已移出当前列表的选中项 → 跳过，不计成功也不计失败。
- 每个成功项的 `updateTask` / `deleteTask` **各自触发 `loadTasksByDate`**，即一次批量操作会产生 N 次全量重查。这是既有性能特征。
- **批量改日期 / 优先级对循环任务会触发 `generateRecurringTasks`**（因为 `updateTask` 里有 `if (recurrence != 'none')` 分支）。所以批量改 priority 会连带重新生成循环实例。
- 完成后 **`finally` 里必做**：清空选中集 + `_batchMode = false` + 只更新一次小组件。
- 结果文案：全跳过（success==0 && failed==0）→ 返回 `null`（**不弹提示**）；否则 `成功{动作} {n} 个任务`，有失败再追加 `，{m} 个失败`。

**批量修改日期对话框**的范围：`firstDate: DateTime(2020)`、`lastDate: DateTime(2030)`（系统日期选择器，与表单里的三框输入器不同）。
**批量优先级对话框的默认选中是 `'white'`** —— 不选任何色直接点「确定」，所有选中任务变白色。

---

## 4. 循环任务（C 节）

> **本节的日期规则已由 `rn/src/core/recurrence.ts` 实现完毕，RN 侧直接调用，不要重写。** 本节说明其语义与代码真实行为的对应关系，便于校验。

### 4.1 触发时机（只有三处）

| 时机 | 调用 | 模板来源 |
|---|---|---|
| 创建循环任务 | `TaskProvider.addTask` 第 4 步 | 刚创建的这条任务 |
| 编辑循环任务 | `TaskProvider.updateTask`（每次保存，**不限字段**） | 编辑后的这条任务 |
| **应用冷启动** | `initialize()` → `autoCheckRecurringTasks()` | 每个 loop 最早的一条 |
| **从回收站恢复循环任务** | `TaskRecycleMixin.restoreTaskFromRecycle` | 回收站里存的**原始 `cplTime`** |

> ⚠️ **编辑循环任务时无论改了什么字段（哪怕只改标题）都会重跑生成器。**
> ⚠️ **完成任务不会触发生成。**
> ⚠️ **恢复循环任务会触发生成，且用的是删除当天的日期**（可能远早于今天）→ 见 §4.3 的「回补」讨论。

### 4.2 `autoCheckRecurringTasks()` — 启动时的模板归并

```dart
recurringTasks = SELECT * FROM tasks WHERE recurrence != 'none';   // 无 ORDER BY
uniquePatterns = {};
for (task in recurringTasks) {
    key = task.loopId ?? '${task.title}||${task.description}||${task.recurrence}||${task.isWord}||${task.rewardPoints}';
    if (!uniquePatterns.containsKey(key) || uniquePatterns[key].cplTime.isAfter(task.cplTime))
        uniquePatterns[key] = task;      // 保留 cplTime 最早的那条
}
await Future.wait(uniquePatterns.values.map(generateRecurringTasks));
```
- **归并键**：有 `loopId` 就按 `loopId`；`loopId` 为空的历史任务用复合键 `title||description||recurrence||isWord||rewardPoints`（`isWord` 拼成 `true`/`false`）。
- 每个模板一个**独立事务**，`Future.wait` 并发。**所有 loop 不在同一事务里。**
- ⚠️ `loopId == null` 的历史循环任务：分组后调 `generateRecurringTasks`，但 `_insertIfNotExistsTxn` **第一行就是 `if (task.loopId == null) return;`** → **这些任务永远不会被生成实例**。归并对它们纯属无效功。既有行为。

### 4.3 生成窗口

```dart
now      = DateTime.now();                      // 含当前时分秒
rangeEnd = now.add(Duration(days: 15));         // 含当前时分秒
next     = DateTime(cplTime.year, cplTime.month, cplTime.day);   // 模板当天 00:00
while (!next.isAfter(rangeEnd)) { ... }
```

- **上界**：`now + 15 天`（含边界日）。
- **起点**：模板 `cplTime` 的**当天 00:00**（时分秒被归零）。
- **无下界** —— 模板很旧会**从旧日期逐日回补**。`cplTime = 1/1`、`now = 1/31` → 生成 46 天。
  - ⚠️ 这个循环**没有次数上限**。一个 2020 年的 monthly 模板会一次性回补 6 年多 ≈ 80+ 行；daily 模板回补 2000+ 天 ≈ 2000 行。**性能与数据膨胀风险需在 RN 侧评估**（`business-rules.md` §6 待核实第 6 项就是这个问题）。
  - ⚠️ **回收站恢复是回补的主要触发入口，且放大得很厉害**：`restoreTaskFromRecycle` 传给生成器的是**回收站里存的删除当天 `cplTime`**。删掉一个 3 个月前的每日循环任务再恢复 → 一次性生成约 90+ 个实例。这条路径在 UI 上完全无感知（没有进度、没有提示），用户只会发现「删除前的老任务全回来了」。
  - ✅ **一个缓解事实**：回补出来的实例**不会触发逾期扣分**——`getOverdueTasks` 硬编码 `recurrence = 'none'`（§2.7），循环实例一律被排除。所以回补只污染列表，不会意外扣用户积分。这降低了「夹到今天起」的紧迫性，但不改变数据膨胀本身。
  - RN 侧 `recurrence.ts` 的 monthly 分支有 `guard < 240` 保护，daily/weekly 无。**这是 RN 侧与 Flutter 侧的差异**，见 §6.6。

### 4.4 三种 recurrence 的推进规则

**daily**
```
_insertIfNotExistsTxn(task, next);
next = next.add(Duration(days: 1));
```

**weekly**
```
while (next.weekday != task.cplTime.weekday) next = next.add(Duration(days: 1));
if (next.isAfter(rangeEnd)) break;             // ← 推进星期几后要重新检查上界
_insertIfNotExistsTxn(task, next);
next = next.add(Duration(days: 7));
```
> ⚠️ Dart `DateTime.weekday`：**周一=1 … 周日=7**。JS `Date.getDay()`：**周日=0 … 周六=6**。RN 侧 `recurrence.ts` 已正确用 `getDay()` 内部自洽（都是「和模板同星期几」），只要**比较双方用同一套编号**即可，不要把 Dart 的 `weekday` 数值直接搬过去。

**monthly**
```dart
int day = task.cplTime.day;                              // 模板的「几号」，固定不变
int daysInMonth = DateTime(next.year, next.month + 1, 0).day;   // 当月天数
day = day > daysInMonth ? daysInMonth : day;              // 月末钳制
var monthlyDate = DateTime(next.year, next.month, day);
if (!monthlyDate.isAfter(rangeEnd)) _insertIfNotExistsTxn(task, monthlyDate);
// 推进到下月 1 号
int nextMonth = next.month + 1, nextYear = next.year;
if (nextMonth > 12) { nextMonth = 1; nextYear++; }
next = DateTime(nextYear, nextMonth, 1);
```
**月末处理规则**：按模板的「几号」取当月同日；**当月没有该日则取月末**（31 号 → 2 月 28/29 号）。
⚠️ **注意这不是「逐月递减」**：3 月 31 号 → 2 月 28 号 → **3 月 31 号**（回到模板日，不是从 28 递增）。RN `recurrence.ts` 的 `Math.min(wantedDay, maxDay)` 是**同样的语义**，正确。
⚠️ 循环变量 `next` 推进到下月 **1 号**后再循环，`daysInMonth` 用 `next` 的年月重算。若模板 `cplTime.day = 31` 且起始月在 2 月，则首个 `monthlyDate` 会被钳到 28/29。

**其它（含 `none`）**：`break`，直接退出，不生成。

### 4.5 去重键

**同一 `loop_id` + 同一天**。**不是按 title 去重。**

```dart
_insertIfNotExistsTxn(txn, task, date):
    if (task.loopId == null) return;                          // ← 无 loopId 直接放弃
    start = DateTime(date.y, date.m, date.d);
    end   = start.add(Duration(days: 1));
    exists = SELECT id FROM tasks
             WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ?
             LIMIT 1;                                          -- 在同一事务内查
    if (exists.isNotEmpty) return;                             -- 已存在则跳过
    instance = task.copyWith(id: null, cplTime: date,
                             isOK: false, completedAt: null, isDeducted: false);
    txn.insert('tasks', instance.toMap());
```

- **已存在同名实例时：静默跳过，不更新、不报错。** 已存在的那条**保持原样**（哪怕内容已被用户改过）。
- 去重查询在**事务内**逐条执行（每插一条查一次），不是批量预查。RN 的 `pickNewDates` 是一次性传入 `exists` 回调——语义等价，但**注意 RN 版要求调用方一次性准备好「已存在 key 集合」**，需要自己写一条 `SELECT cpl_time FROM tasks WHERE loop_id = ?` 把结果转成 `YYYY-MM-DD` 集合。
- 整批生成在**单个事务**内完成（每个 loop 一个事务，§4.2）。

### 4.6 新实例的字段

| 字段 | 值 |
|---|---|
| `id` | `null` → SQLite 自增 |
| `cpl_time` | 目标日期（`00:00`） |
| `is_ok` | `false` |
| `completed_at` | `null` |
| `is_deducted` | `false` |
| `loop_id` / `title` / `description` / `is_word` / `reward_points` / `priority` / `recurrence` / `created_at` | **复制模板** |

> ⚠️ **`created_at` 也被复制**（模板的创建时间），不是新实例的生成时间。

**标签是否复制：不复制。** `_insertIfNotExistsTxn` 只 `txn.insert('tasks', ...)`，**从不写 `task_tags`**。
→ 循环任务的**模板那条**可以有标签（用户创建/编辑时打的），但**所有自动生成的实例都没有标签**。既有行为，重写时保持同样行为，否则「循环任务带标签」会变成新特性。（这回答了 `business-rules.md` §6 待核实第 4 项：**代码确实不带标签**。）

> ⚠️ **`copyWith(id: null)` 与 `copyWith(completedAt: null)` 在 Dart 里都是无效的**：`copyWith` 的实现是 `id ?? this.id` / `completedAt ?? this.completedAt`，传 `null` 会走 else 分支取模板的值。
> - `id` 无害：`toMap()` **不含 id**，`insert` 时被忽略，最终仍拿到新自增 id。**结果正确，但原因是 `toMap()` 兜住的，不是 `copyWith` 生效。** RN 实现时不要试图让「传 null 清空字段」生效——插入时直接省略 `id` 即可。
> - `completedAt` **有真实副作用**：若模板任务已完成（`completed_at` 非空），生成出的每个新实例会得到 **`is_ok = 0` 但 `completed_at` = 模板的旧时间戳**。见 §6.2 k。

---

## 5. 界面行为清单（D 节）

### 5.1 页面 → 操作 → 数据变化

#### ① `TasksHomePage`（应用外壳）

| 区域 | 操作 | 数据变化 |
|---|---|---|
| AppBar 左侧 | 点菜单图标 | 打开顶部滑出菜单（无数据变化） |
| AppBar 右侧 | — | 只读显示 `PointsProvider.currentPoints`，**不显示在任务模块的独立查询里** |
| AppBar / 列表 | **向下快速滑动**（`primaryVelocity > 300`） | 打开顶部滑出菜单 |
| 列表**已滚动到顶**时 | 向下快速滑动 | 打开顶部滑出菜单 |
| FAB（仅 tab 0） | 点 `+` | `taskCreateMode == minimal` → 快速添加对话框；否则 → 完整表单 bottom sheet |
| 底部导航 | 切 tab | `AppStateProvider.setCurrentTab`；**切回 tab 0 时额外 `selectDate(now)` + 滚动日历到今天** |
| 生命周期 | App `resumed` | `TaskProvider.syncFromWidget()` → 可能批量改 `is_ok` / `completed_at` + 结算积分（§3.2） |
| 首次构建 | — | 依次 `PointsProvider.initialize()` → `TagProvider.initialize()` → `TaskProvider.initialize()` → `ShopProvider.initialize()` → 恢复排序选项 → 若 `rememberFilters` 恢复筛选条件 → 滚动日历到今天 |

#### ② `TaskPage`（任务列表，tab 0）

| 元素 | 操作 | 数据变化 |
|---|---|---|
| 标题 `今日任务 (YYYY-MM-DD)` | **双击** | `selectDate(now)` + 日历滚回今天，重载当日列表 |
| 进度条 | — | 只读，`completed/total` 基于**当前 Tab 过滤后**的列表 |
| 日历条（31 天） | 点某天 | `selectDate(date)` → `loadTasksByDate` 重查当日 |
| 标签筛选行 | 展开/收起 | 无（本地状态） |
| 标签筛选行 | 点某个标签 chip | `getTaskIdsByTag(tagId)` → `selectTag(tagId, taskIds)` → **前端内存过滤**；同时写 `settings.lastTagFilterId` |
| 标签筛选行 | 点「全部」 | `clearTagFilter()` + 写 `lastTagFilterId = null` |
| 三个 Tab（全部/普通/循环） | 左右滑动 | **居中 toast「当前显示：X任务」**（1 秒）；无数据变化 |
| 进度条下方 4px 指示条 | 随 Tab 滑动动画 | 无 |
| 排序指示条 | 点「更改」 | 排序 bottom sheet；选择后写 `settings.taskSortOption` |
| 排序指示条 | 仅在 `sortOption != defaultOrder` 且**非批量模式**时显示 | — |
| 筛选状态条（底部悬浮） | 点「清除」 | `clearFilters()` + `settings.clearAllFilters()`；**仅在 `hasActiveFilter` 时显示** |
| 简单卡片 | **点复选框/标题区域** | `completeTask` / `uncompleteTask` + 积分结算（§3.2/3.3） |
| 简单卡片 | **点右侧箭头** | 展开/收起详情（描述 + 标签行），**无数据变化** |
| 简单卡片 | **长按** | 打开编辑表单 |
| 简单卡片 | **从右向左滑** | 弹出删除确认 → `deleteTask`（循环任务三选项） |
| 富卡片 | 点 Checkbox | 同「点复选框」 |
| 富卡片 | 点编辑图标 | 打开编辑表单 |
| 富卡片 | 点删除图标 | 弹出删除确认 → `deleteTask` |
| 批量卡片 | 点任意位置 | `toggleTaskSelection(task.id)` |
| 空态 | 点「清空搜索」 | `clearSearch()`（`_searchQuery` 本就为空，等于无操作） |

> **`hasActiveFilter` 不包含标签筛选与搜索**：它只看 `priorityFilter / completionFilter / recurrenceFilter`。所以选了标签后底部不出现筛选状态条。

#### ③ 顶部滑出菜单（`TopSlideMenuWidget` + `MenuPanelWidget`）

| 元素 | 操作 | 数据变化 |
|---|---|---|
| 遮罩层 | 点击 | 关闭菜单 |
| 搜索框 | 聚焦 | 进入搜索模式（显示返回箭头、去掉放大镜图标） |
| 搜索框 | 输入（**500ms 防抖**） | `searchAllTasks(query)` → `searchTasks()` → 展示 `searchResults` |
| 搜索框 | 点 `×` | `clearSearch()` |
| 搜索框 | 点漏斗图标 | 展开/收起高级搜索面板；**展开时立即执行一次搜索** |
| 高级搜索 | 改开始/结束日期 | `_performAdvancedSearch()`；结束日期早于开始日期 → 显示「结束日期不能早于开始日期」并**中止查询** |
| 高级搜索 | 改完成状态 | 同上 |
| 高级搜索 | 点「重置」 | 清空三个条件并重搜 |
| 搜索结果 | 点某条 | `selectDate(task.cplTime)` + 关闭菜单 + 跳到那一天 |
| 搜索结果 | 点「清空搜索」 | `clearSearch()` |
| 菜单按钮 · 排序 | 点 | 关闭菜单 → 排序 bottom sheet |
| 菜单按钮 · 批量操作 | 点 | **切换** `_batchMode`（可重复点开/关）+ 关闭菜单 |
| 菜单按钮 · 筛选 | 点 | **就地展开/收起筛选面板**（菜单不关闭） |
| 菜单按钮 · 刷新 | 点 | `loadTasksByDate(selectedDate)` 重查当日 + 关闭菜单 |
| 筛选面板 | 改优先级/完成状态/任务类型 | 内存过滤 + **立即写 `settings.lastXxxFilter`** |
| 筛选面板 | 点「重置」 | `settings.clearAllFilters()` + `clearFilters()` |
| 筛选面板 | 「记住筛选状态」开关 | `settings.setRememberFilters(value)` |
| 菜单按钮 · 批量操作 | 菜单图标上的高亮边框表示当前处于批量模式 | — |

#### ④ `RecycleBinPage`

| 元素 | 操作 | 数据变化 |
|---|---|---|
| AppBar 右侧扫帚图标 | 点 | 清空确认对话框 → `clearRecycleBin()` → `DELETE FROM recycled_tasks`（运行时路径 `task_repository.dart:390`，mixin `:314` 是死代码） |
| 卡片恢复图标 | 点（非循环） | 确认「确定要恢复这个任务吗？」→ `restoreTaskFromRecycle`（§3.8） |
| 卡片恢复图标 | 点（循环） | 三选一：「仅恢复当天」/「恢复循环」/ 取消（§3.8） |
| 卡片彻底删除图标 | 点 | **`deleteFromRecycle`，无二次确认** → 运行时路径 `task_repository.dart:380`（mixin `:305` 是死代码） |
| — | 页面 init | `loadRecycledTasks()` |

#### ⑤ 各类对话框汇总

| 对话框 | 触发 | 按钮 |
|---|---|---|
| 快速添加 | FAB（minimal 模式） | 取消 / 添加（回车等同） |
| 任务表单 | FAB / 长按卡片 / 编辑图标 | 保存（右上角文字按钮）/ 取消（下滑或点遮罩） |
| 删除确认（非循环） | 滑动 / 删除图标 | 取消 / 删除 |
| 删除确认（循环） | 同上 | 取消 / 仅删除当天 / 删除全部 |
| 更新循环任务 | 编辑循环任务且 6 个字段之一变化 | 仅此任务 / 全部更新 |
| 恢复确认（非循环） | 回收站恢复图标 | 取消 / 恢复 |
| 恢复确认（循环） | 回收站恢复图标 | 取消 / 仅恢复当天 / 恢复循环 |
| 清空回收站 | 回收站 AppBar | 取消 / 清空 |
| 排序选择 | 排序指示条「更改」/ 菜单「排序」 | 5 个 Radio + 点任意项即**立即保存并关闭** |
| 批量完成 / 取消完成 / 删除 | 批量操作栏 | 取消 / 确定（含数量文案） |
| 批量优先级 | 批量操作栏 | 5 个 chip（默认选中 `white`）/ 取消 / 确定 |
| 批量日期 | 批量操作栏 | 日期行（点开系统日期选择器，2020–2030）/ 取消 / 确定 |
| 批量标签 | 批量操作栏 | 标签 chips / 取消 / 确定；无标签时显示「暂无标签，请先创建标签」 |
| 三框日期输入 | 表单的日期字段 | 取消 / 确定；`barrierDismissible: false`（点遮罩**不**关闭） |

### 5.2 「不看代码猜不到」的交互细节

1. **点卡片标题 = 切换完成状态**（不是打开详情）。想看详情得点右侧箭头。
2. **点已展开的卡片标题 = 收起**（不切换完成状态）。同一个手势有两种含义，取决于展开状态。
3. **长按卡片 = 编辑**（不是删除、不是多选）。**没有长按进入批量模式**这个交互。
4. **批量模式只能从菜单进入**，进入后卡片变成勾选框样式。
5. **日期标题双击 = 回到今天**。
6. **向下快速滑动打开菜单**，且要求**列表已滚到顶部**。
7. **切 tab 回来会重置日期到今天**。
8. **App 切回前台会自动同步小组件的勾选状态**（按 task id 匹配）。
9. **创建任务后首页自动跳到该任务所在日期**（`addTask` 末尾 `loadTasksByDate(task.cplTime)`）。在「未来」创建任务会跳到未来。
10. **编辑任务保存后也跳到该任务的新日期**。
11. **「今日任务」vs「任务」标题会随选中日期切换**。
12. **空列表有三种不同文案**：有搜索词 → 「未找到匹配的任务」+ 清空按钮（实际不可达，见 §6.2）；Tab 2 → 「暂无循环任务」；其它 → 「暂无任务」+ 「点击 + 添加新任务」。
13. **筛选状态条在有筛选时悬浮在列表底部**，会遮挡最后一条卡片的一部分。
14. **进度条的分母受 Tab 过滤影响**：切到「循环」Tab，进度条只统计循环任务。
15. **非当天任务的完成/编辑被设置开关拦住**（默认两个开关都是 `false`），提示「可在设置中开启高级模式」。**但这个门禁只在 UI 层**——批量操作、小组件同步、Provider 直接调用**都不受门禁约束**。
16. **完成/取消完成的 toast 是居中浮层**（OverlayEntry），不是底部 SnackBar；警告色 3 秒、普通色 1 秒。
17. **有 3 秒防抖**防止连续点完成刷 toast —— 但如 §3.2 所述该逻辑实际是死代码。
18. **循环任务实例不带标签**，所以富卡片上的标签行对自动生成的实例是空的。
19. **回收站卡片上的「彻底删除」没有二次确认**，误触即永久丢失。
20. **回收站只保留 10 条**，删第 11 条时最早那条被静默清掉。
21. **批量操作完成后自动退出批量模式并清空选择**（在 `finally` 里，即使出错）。
22. **批量改优先级对话框默认选中「白色」**，直接点确定会把所有选中任务刷成白色。
23. **表单的「单词任务」不是一个独立开关**，而是「单词」标签的勾选状态（§3.1 入口 1）。
24. **设置里的「任务类型」筛选与顶部的三个 Tab 是两套独立机制**，可叠加、可互相矛盾（如筛「循环」+ 停在「普通」Tab → 空列表）。
25. **积分扣减允许余额变负**。

---

## 6. 边界、坑与文档不一致

### 6.0 跨模块交叉依赖（与积分/回收站模块的联合裁决项）

> 以下 4 条**不能由本模块单方面决定**，需与积分/回收站模块（`spec-points-shop.md`）同步。每条都给了我的建议与理由。

#### 来源标注（traceability）

与 `spec-points-shop.md` 文首的 traceability 表同一标准。三类来源区分如下——**引用本表结论时请按此标注出处**：

| 标记 | 含义 | 验证强度 |
|---|---|---|
| **【实证】** | 我直接打开被引用的 Dart 文件 / DDL，逐行核对过行号、SQL、字段 | 强：可按给出的 `文件:行号` 复现 |
| **【交叉核对】** | 与 general-purpose-2（`spec-points-shop.md` 作者）往返核对后的共识；代码位置由我或对方任一方实证 | 中：结论可靠，行号以本文档给出的为准 |
| **【引 QA】** | 引用 `docs/migration/spec-review.md`（**作者：software-qa-engineer-1，任务 #14**）。我**未独立复核**其中每一行，仅核实了涉及任务模块的部分 | 弱：引用前请自行复核 |

| # | 交叉点 | 本模块的立场 |
|---|---|---|
| X1 | **恢复任务时 id 会变**，导致 `task_tags` 与 `points_records` 双双指向失效 | 【引 QA + 交叉核对】**🔧 裁决已修订（M1，第二轮 QA 核查后）：改为「修」。** 原裁决为「照搬（id 变），不修」，**现已作废**——QA 确认「必须同 PR 改两侧」的前置条件在 M1 已满足（两仓储由同一裁决统筹），且不修的代价是「不冲销 + 重复加分」两个实打实的缺陷。**修法**：恢复时写回 `recycled_tasks.task_id`。**⚠️ 早期版本曾写「同时同步 `UPDATE` 4 处引用」，该说法已作废**（U1 裁决）——因为 id 写回原值后，`task_tags.task_id` / `points_records.related_id`（含 `task_complete`/`task_uncomplete`/`overdue_deduct`）/ `pomodoro_records.related_task_id` 这些行**从未被删除**，会自动重新指向真实存在的任务，**不需要任何 `UPDATE`；加了反而可能把正确引用改错**。真正必须做的是**主键冲突检查**（撞了回滚，绝不静默换 id）。两条恢复路径（「恢复循环」/「仅恢复当天」）**必须合并为同一仓储方法**，否则「仅恢复当天」分支可绕过修复。详见 §3.8「🔧 M1 裁决」。 |
| X2 | **循环任务回补无下界**，回收站恢复是主要放大入口（删 3 个月前的 daily 再恢复 → 回补 90+ 行） | 【实证 + 交叉核对】**【照搬】RN 侧与 Flutter 侧一致**——照搬，暂不夹到「今天起」。 理由：回补是既有行为，改了会让 RN 与 Flutter 在同一份数据上产生不同列表，迁移期无法对账。**但缓解了一个关键担忧**：回补实例 `recurrence != 'none'`，被 §2.7 的 `recurrence = 'none'` 排除，**不会触发逾期扣分**，所以不会意外扣用户积分。剩下的是数据膨胀与列表污染，非资金风险。**建议 M1 照搬 + 在真库上跑 `SELECT COUNT(*) FROM tasks WHERE recurrence != 'none' AND cpl_time < date('now','localtime')` 评估实际规模**，再决定是否在 M2 收敛。 |
| X3 | **删任务时 `task_tags` 的清理时机** | 【实证 + 交叉核对】**🔧 已修订（V1 + V1 补充 + V3）：移入回收站时不清理，永久删除时同事务清理。**<br>**原表述「照搬不清理，理由是 §7 验收第 1 条要求行数一致」已作废**——该理由属于 V1 之前的推理（当时 purge 挂在启动时）。按 V1，清理点在「永久删除的那一刻」，**迁移期的行数一致不受影响**（迁移不触发运行时删除路径）。<br>**现行口径**：①移入回收站 → **不清理**，因为恢复时 id 写回原值、`task_tags` 行会自动重新接回（这正是 H2「标签自动恢复」的成立前提，U1）；②该任务被**永久删除**时（回收站裁剪 / 单条永久删除 / 清空 / 批量物理删除循环任务）→ **同事务**清理。⇒ 孤儿生命周期从「永久」缩短为「0」（V3），§7「孤儿数为 0」在迁移时点与运行期同时成立。<br>⚠️ 清理条件用 `task_id` 不是 `recycled_tasks.id`（V6）；⚠️ 孤儿分`task_id` / `tag_id` 两类（V7）。 |
| X4 | **`schema-v3.md` §5.4 与 §7 自相矛盾** | 【实证】§5.4 说「`task_tags` 很可能有孤儿行，不要假设外键已清理」；§7 验收第 3 条却要求「孤儿数应为 0」且必须迁移前后一致。**这两条不可能同时成立**（若旧库有孤儿，§7 第 3 条必然失败）。**注**：general-purpose-2 指出该矛盾**仅在旧库确有孤儿时才卡住验收**，故应先在真库验证再决定是否改契约文件。 |
| X6 | **`DatabaseTaskMixin` 不是整体死代码** | 【实证 + 交叉核对】⚠️ 精确表述：**回收站相关的 6 个方法里，5 个是死代码，但 `getRecycledTasks()` 是活的**——`data_export_page.dart:300` 经 `DatabaseService.instance` 调用，**数据导出功能依赖它**（导出全 15 列）。⚠️ **本条已于第二轮 QA 核查修订**：初版写「6 个方法全是死代码」，实测 `getRecycledTasks` 有两个同名实现且**两个都是活代码**（mixin 版被数据导出调用，repository 版被 `task_provider_core_mixin.dart:100` 调用）。<br>**⚠️ 字段差异的更正**：QA `spec-review.md` P0-1 曾写「mixin 版返回 5 字段 / Repository 版 10 字段」，**该理由不成立**——我逐字核对两版 SQL **字符级相同**、走同一个 `RecycledTask.fromMap`、`toMap()` 都是 15 字段，唯一差异是 `await database` vs `await _db`。P0-1 的**结论**（两个都活、都别当死代码删）正确，**理由**错误；**不要按「字段数不同」做防御性映射**。<br>另：`getAllTasks()` **也是活的**——`data_export_page.dart:278` 调用，SQL 为 `SELECT * FROM tasks ORDER BY cpl_time DESC`（无 LIMIT，全量导出）。<br>注意 `getAllTasks` 与 `TaskRepository` 的同名方法**不是同一条路径**：`TaskRepository` 刻意不暴露 `getAllTasks()`（见 `task_repository.dart:15` 注释），运行时列表一律走 `getTasksForDate`。<br>→ **RN 实现数据导出时需要这两条查询**，别因为「mixin 是遗留的」而漏掉；但实现回收站相关逻辑时**只能参考 `TaskRepositoryImpl`，绝不能参考 mixin**。 |

### 6.1 代码 vs 文档不一致

| # | 项 | `business-rules.md` 写的 | **代码真实行为** | 建议 |
|---|---|---|---|---|
| 6.1.1 | 循环任务生成 | §2.5「`loopId` 为空的历史任务用复合键归并」 | 归并确实发生，但 `generateRecurringTasks` → `_insertIfNotExistsTxn` 首行 `if (task.loopId == null) return;` → **这批任务一个实例都生成不出来**。复合键归并对它们是无效功。 | **以代码为准**：`loop_id IS NULL` 的循环任务直接跳过，不生成。建议在 `business-rules.md` §2.5 加注。 |
| 6.1.2 | 逾期条件 | §1.3「`cpl_time < now`」 | 实际 SQL 是 `cpl_time < 当天 00:00`（变量名 `endOfDay` 是误导，实际是当天零点）。**只处理昨天及更早**；今天凌晨到现在的任务不算逾期。 | **以代码为准**，但变量名应改。文档改为「`cpl_time < 当日 00:00`」。 |
| 6.1.3 | 逾期范围 | §1.3 未提循环任务 | SQL 硬编码 `recurrence = 'none'` → **循环任务永不逾期扣分**。 | **以代码为准**，文档 §1.3 补一句。 |
| 6.1.4 | `is_deducted` 置位 | §1.3「先扣分成功，再置 `is_deducted=1`」 | 顺序对，但 `markTaskDeducted` 在 `if` **之外无条件执行** —— `rewardPoints==1`（扣 0 分）或已有流水时，仍会置 1，该任务此后永久退出逾期候选集。 | **以代码为准**，文档补注。 |
| 6.1.5 | 逾期触发时机 | §1.3 未说明 | **无定时任务**。仅 `TaskProvider.initialize()`（冷启动首页）跑一次。跨午夜不触发。 | **以代码为准**，文档补注。 |
| 6.1.6 | 批量删除循环任务 | 未描述 | `deleteAll=true` **不进回收站**，物理删除该 loop 中「不早于本任务」的全部实例，不在事务内。 | 以代码为准。 |
| 6.1.7 | 月末处理 | §2.2「当月没有该日则取月末……月末后下个月从 1 号重新计算」 | 描述准确。补充：循环变量推进到下月 **1 号**后重算 `daysInMonth`，**不是从月末递增**（31 号 → 2/28 → 3/31）。 | 文档措辞可更明确，行为一致。 |
| 6.1.8 | `recycled_tasks.loop_id` | §2.2 标注为「v3 才补」 | 一致。但注意**遗留方法 `DatabaseTaskMixin.moveTaskToRecycleBin()` 不搬 `loop_id`**（测试已标注已知行为），运行时路径 `TaskRepositoryImpl` 才搬。 | 以运行时路径为准；RN 不要照抄 mixin 版本。 |

### 6.2 「看起来像 bug 但不能改」清单

| # | 行为 | 为什么不能改 |
|---|---|---|
| a | `_searchQuery` 恒为 `''`，于是①`filterBySearchQuery` 永不过滤；②`EmptyStateWidget` 的「未找到匹配的任务」分支**永不可达**；③菜单里的搜索是**完全独立的第二套结果**（`searchResults`），与列表过滤无关 | UI 从不调 `setSearchQuery`。搜索功能实际可用（走 `searchResults`），只是空态文案那条路是死的。RN 照抄会保留一个不可达分支；**建议 RN 直接删掉该分支并在本文档留档**。 |
| b | 编辑任务会**重置 `created_at` 为当前时间**（表单构造 `Task` 时不传 `createdAt`） | 既有行为。影响「按创建时间」排序与统计。改它会导致历史数据语义变化，需产品决策。 |
| c | 取消完成的 toast 显示任务**当前** `rewardPoints`，与实际扣减额（历史流水值）可能不符 | 纯展示 bug，不影响账目。 |
| d | `markTaskDeducted` 无条件置 1（即使没扣成钱） | 幂等设计的一部分。它是「门 1」的置位动作；改了会让已扣过的任务重新进入逾期候选集，**导致重复扣分**（此时 `points_records` 的旧流水仍会被门 2 挡住，但一旦 id 因 H1 变更而失效，门 2 也会失效——见 §3.5 红线）。 |
| e | 插入重复时**静默跳过且无任何 UI 提示**，`addTask` 返回 `id == null` | 既有行为。RN 若改成抛错或提示，会改变用户可见行为。 |
| f | 删除任务移入回收站时**不立即**清理 `task_tags`（行要留给 H1 的 id 写回，使标签自动接回）；该任务被**永久删除**时才同事务清理（V1） | 「不立即清理」不是缺陷，是**标签自动恢复的成立前提**（U1）。真正的行为差异在永久删除阶段，V1 已定为同事务清理。⚠️ 注意：本条**不是「清理孤儿是迁移期的事」**——那个说法属于 V1 之前的推理，已作废。 |
| g | 月度缓存失效用 `.clear()` 全清（仅 `deleteTask`） | 保守做法，注释说明是因为循环任务批量删除会跨月。 |
| h | 「仅恢复当天」是**非原子的 delete + add**，且 `copyWith` 保留了 `loopId` 与 `id` | ⚠️ **本条已被「两条恢复路径合并」裁决取代，不再是「照搬」对象**。RN 侧统一走单一仓储方法 `restoreTask(recycledTaskId, { keepRecurrenceChain })`：两条路径都保留原 id、都在**单事务**内，顺带修掉「非原子 delete+add」与「任务彻底丢失」窗口。`loop_id` 仍**照搬保留**（U2：`getRecurringTasks()` 按 `recurrence != 'none'` 过滤，脏 `loop_id` 不会被生成器取到，零实际影响）。 |
| i | `sortTasks` 的 Dart `List.sort` **不稳定** | RN 的 `Array.sort` 是稳定的，同 key 项顺序会与 Flutter 不同。**建议 RN 显式加 `id` tiebreaker**（更可预测），但这本身是行为差异，需在 RN 侧测试中确认可接受。 |
| j | 批量操作逐项 `loadTasksByDate`（N 次全量重查） | 性能特征，非正确性问题。 |
| k | **循环实例继承模板的 `completed_at`**：`copyWith(completedAt: null)` 因 `?? this.completedAt` 兜底而失效，若模板任务已完成，新实例得到 `is_ok=0` 但带旧的 `completed_at` 时间戳 | 已验证：`task_model.dart:64` 是 `completedAt: completedAt ?? this.completedAt`，`task_scheduler_service.dart:96` 传 `completedAt: null`。后果：这些实例在「按完成时间」排序里被当作有完成时间；`isOK=false` 但 `completedAt != null` 的组合在整个代码库里**没有任何读取方**能正确解释。**照抄，不要"修好"**——改了会让循环任务的日期分布变化。若要修，需同时确认 `business-rules.md` §2.4 的表述也要改。 |

### 6.3 依赖 Flutter 特有能力的行为，RN 需换方案

| Flutter 机制 | 用在哪 | RN 替代方案 |
|---|---|---|
| `Dismissible` + `confirmDismiss` | 简单卡片右滑删除 | `react-native-gesture-handler` 的 `Swipeable`，或 `FlatList` + 手势阈值（阈值需定，Flutter 默认是滑动超过 1/4 宽度） |
| `OverlayEntry` + `SlideTransition` + `CurvedAnimation` | 顶部滑出菜单、居中 toast | `Modal` + `Animated.View`（`translateY` 从 `-100%` 到 `0`）。**注意 toast 用的是全屏 Overlay，不是 SnackBar** |
| `ChangeNotifier` + `Provider` | `TaskProvider` 状态中枢 | Zustand / Redux / Context。**必须保留 `notifyListeners()` 的触发时机**，因为多处逻辑依赖「改完立刻 reload 再通知」 |
| `HomeWidget` 插件 | 桌面小组件读写 | RN 侧需自建 AppWidget 桥（原生模块）。**M1 若不做小组件，`syncFromWidget` 与 `_performWidgetUpdate` 整体跳过**——但要注意这会改变「App 恢复时同步勾选」这一行为 |
| `showDatePicker`（Material） | 批量改日期（2020–2030） | `@react-native-community/datetimepicker` |
| 三框日期输入对话框 | 表单日期、高级搜索起止日期 | 需自建（三个 `TextInput` + 数字键盘 + 校验）。**注意它有独立校验逻辑**：月份 1–12、日按 `daysInMonth`、范围校验、错误文案 |
| `TextInputType.number` + `FilteringTextInputFormatter.digitsOnly` | 三框输入、积分输入 | `keyboardType="number-pad"` + 正则过滤 |
| `DateFormat`（intl） | 全模块日期显示 | `date-fns` / `Intl` / 手写 `pad2` |
| `Colors.X.withValues(alpha:)` | 全模块配色 | RN 无 alpha 修饰符，需 `hexToRgba()` 或直接用 8 位 hex |
| `LinearProgressIndicator` / `FilterChip` / `ChoiceChip` / `RadioListTile` / `Wrap` | 进度条、筛选 UI | 自建或用社区组件。`Wrap` 的流式换行布局需注意 |
| `showModalBottomSheet(isScrollControlled: true, useSafeArea: true)` | 表单、排序面板 | RN `Modal` + `KeyboardAvoidingView`（表单有 `viewInsets.bottom` 适配） |
| `Dismissible` 的 `Key('task-${id}')` | 列表 item 身份 | `keyExtractor` |
| `TabController` + `TabBarView` + `animation.value` | 三 Tab 与 4px 指示条 | `react-native-tab-view` 或自建；指示条跟随手势需要 `Animated` |
| `ListView.builder` + `NotificationListener<ScrollNotification>`（判断是否在顶部） | 菜单滑动手势前置条件 | `onScroll` 的 `contentOffset.y <= 0` |
| `Timer` 防抖（300ms 小组件 / 500ms 搜索 / 500ms Tab 指示条） | 多处 | `setTimeout` + `clearTimeout`，注意清理 |
| `Random()`（`loopId` 生成） | 循环系列 id | `Math.random()`（`recurrence.ts` 的 `generateLoopId` 已封装） |
| `DateTime.weekday`（1=Mon） | weekly 推进 | `Date.getDay()`（0=Sun）。**编号体系不同，比较时必须两侧统一** |
| `intl` 的 `DateFormat('MM月dd日')` 等 | 显示层 | 手写 |

### 6.4 RN 侧现有代码需要修正的地方

| # | 位置 | 问题 |
|---|---|---|
| 6.4.1 | `rn/src/repo/types.ts` | `RecycledTaskRow.recycled_at` → 应为 **`deleted_at`**。✅ **已修正** |
| 6.4.2 | `rn/src/repo/types.ts:48-64` | `RecycledTaskRow` 缺 **`task_id`** 字段 |
| 6.4.3 | `rn/src/repo/types.ts:100-108` | `ShopItemRow` 用了 `cost_points` / `item_name` / `stock` / `is_active`，与 `schema-v3.md` §2.5（`price` / `name` / 无 `stock` / 无 `is_active`）不符。**超出任务模块范围，但同属 `types.ts`，建议一并核对** |
| 6.4.4 | `rn/src/core/recurrence.ts:75` | monthly 的 `guard < 240` 是 Flutter 侧**没有**的保护，会导致起始模板很旧时（> 240 个月 ≈ 20 年）生成的月份数与 Flutter 不同。**若追求 1:1，需移除该 guard 或改为可配置**；若保留，需在本文档留档为「有意偏离」 |
| 6.4.5 | `rn/src/db/schema.ts:99` | `tags.is_system INTEGER NOT NULL DEFAULT 0` —— 与 `schema-v3.md` §2.3 一致，但 `Tag.defaultTags` 里 4 个默认标签都是 `is_system = 1`。**新建库时 `SEED_SQL` 没有插入这 4 个默认标签**，`TagProvider._createDefaultTags` 的等价逻辑在 RN 侧需补上，否则「单词」联动标签（§3.1）会失效 |
| 6.4.6 | `rn/src/db/index.ts` | 已正确用 `executeSync`。**新增查询务必同步用 `executeSync`**；写操作用 `writeBatch()`，**事务内禁止 `executeSync`** |

### 6.5 仍需人工确认的问题

| # | 问题 | 为什么不能确定 |
|---|---|---|
| a | `user_points` 初始值 | `SEED_SQL` 写 `points = 0`，而 `DatabasePointsMixin.getUserPoints()` 在表为空时插入 `UserPoints()`（默认 0）。一致。但**旧库里若 `user_points` 表为空行（而非表空）**，`getUserPoints()` 会走 `result.isEmpty` 分支插入新行——需确认旧库是否可能有这种状态。 |
| b | `monthly` 在 `guard` 移除后是否会触发性能问题 | 取决于用户库中循环任务的最早 `cpl_time`。**建议在真库上跑 `SELECT MIN(cpl_time) FROM tasks WHERE recurrence != 'none'` 确认。** |
| c | 小组件在 M1 是否实现 | 影响 §3.2 的「App 恢复时同步勾选」是否保留。属产品决策。 |
| d | 循环任务回补（无下界）是否要夹到「今天起」 | ✅ **已裁决（V13 / X2）**：**【照搬】RN 侧与 Flutter 侧一致**——回补照搬，不夹到「今天起」。理由：改了会让同一份数据在 Flutter 与 RN 跑出不同列表，**迁移期无法对账**；且回补实例 `recurrence != 'none'` 被逾期 SQL 排除 → 只造成数据膨胀与列表污染，**不扣积分**。真实库实测最老循环实例 2023-11-08（约 40 个月、几十行），危害有限。**延后到 v6.x** 按真实规模收敛。 |
| e | `TaskSortOption` 排序的稳定性差异（§6.2 i） | 需实际比对两版排序结果后决定是否加 tiebreaker。 |
| f | `task_tags` 孤儿行数量（旧库的存量） | `schema-v3.md` §6 待实测第 3 项，仍未回填。⚠️ **但这已不影响运行期**：按 V1，清理点在永久删除那一刻（不依赖启动时存量），故旧库有多少孤儿都不影响「运行期孤儿恒为 0」；存量只需靠 `purgeOrphanTaskTags()` 或 M2 手动入口清一次。 |

---

## 7. RN 实现检查清单

写完后逐条核对：

- [ ] `getTasksForDate` 的 `ORDER BY` 五个键一个不差（`is_ok ASC` → CASE priority → `cpl_time ASC` → `id DESC`）
- [ ] 插入前重复检测的两个分支（loop 走 `loop_id`+当天；否则走 `title`+`description`+当天，且 `description IS NULL` 要单独处理）
- [ ] 重复时**静默跳过**，不抛错不提示
- [ ] `addTask` 结尾会 `loadTasksByDate(task.cplTime)`（跳日期）
- [ ] 循环任务 `loopId == null` 时**跳过生成**（`business-rules` 说的复合键归并实际无效）
- [ ] 生成窗口 `now+15d`、起点模板当天 00:00、**无下界**
- [ ] monthly 用 `Math.min(模板日, 当月天数)`，循环变量推到下月 1 号
- [ ] weekly 用 `getDay()`（不是 Dart 的 `weekday`）
- [ ] 去重是 `loop_id` + **同一天**，不是 title
- [ ] 循环实例**不写 `task_tags`**
- [ ] 循环实例**继承模板的 `completed_at`**（不是清空）——`copyWith` 传 null 无效，见 §6.2 k
- [ ] 完成时 `completed_at` 写 `nowLocalIso()`，不是 `cpl_time`
- [ ] 完成**不**触发生成下一批
- [ ] 取消完成扣分取**历史流水的 points**，不是 `rewardPoints`
- [ ] 逾期扣分**先扣分后置 `is_deducted`**
- [ ] `markTaskDeducted` **无条件执行**（RN 侧方法名为 `catchUpOverdueDeduction`）
- [ ] 逾期查询带 `recurrence = 'none'` 且 `cpl_time < 当天00:00`
- [ ] 逾期只在冷启动跑一次（无定时器）
- [ ] 删除是**搬移到 `recycled_tasks` + 删源行**（单事务），不是打标记
- [ ] 删除时搬 `loop_id`
- [ ] `deleteAll=true` **不进回收站**，只删「不早于本任务」的实例
- [ ] 回收站清理保留最近 **10** 条
- [ ] 🔧 恢复时 `loop_id` / `is_ok` / `completed_at` / `is_deducted` / `created_at` 全部还原，**且 `id` 写回原 `recycled_tasks.task_id`**（M1 已改为「修」，见 §3.8）
- [ ] 🔧 恢复**不做任何引用改写 `UPDATE`**——id 写回原值后 `task_tags` / `points_records`（3 种 type）/ `pomodoro_records` 的引用自动有效；加了反而可能改错
- [ ] 🔧 `recycled_tasks.task_id` 为 NULL 时降级为自增插入，不报错
- [ ] 🔧 两条恢复路径（「恢复循环」/「仅恢复当天」）**合并为同一仓储方法**，单事务、均保留原 id；「仅恢复当天」不再是 delete+add 两步
- [ ] 🔧 恢复时显式检查 `tasks.id` 是否已被占用，撞了**回滚并提示**，绝不静默换 id
- [ ] 删除任务**移入回收站时不清理** `task_tags`（行要留给 H1 的 id 写回→ 标签自动接回）；**永久删除时同事务清理**（V1）：回收站裁剪 / 单条永久删除 / 清空 / 批量物理删除循环任务（V1 补充，勿漏）
- [ ] 🔴 清理 `task_tags` 的条件用 **`task_id`**、永不用 `recycled_tasks.id`（V6）；且**必须先删 `task_tags` 再删 `recycled_tasks`**（子查询依赖后者还在）
- [ ] 单测用 `id ≠ task_id` 的数据 + **反向断言**（其他活任务的关联原样保留）（V6）
- [ ] 断言「跑完四条永久删除路径后 `task_tags` 孤儿数= 0」（V8 验收）
- [ ] 数据导出用 `SELECT * FROM tasks ORDER BY cpl_time DESC`（走 `DatabaseTaskMixin.getAllTasks` 的等价查询，**不是** Repository，见 §6.0 X6）
- [ ] 🔧「仅恢复当天」已并入统一恢复方法（见上一条），**不再是** `copyWith` + 先删回收站再 add 的非原子两步；它只是把 `recurrence` 固定为 `'none'` 后走同一条单事务路径
- [ ] 标签白名单筛选在 `tagIds` 为空时返回**空列表**
- [ ] Tab 过滤与 `recurrenceFilter` 是两套独立机制
- [ ] 搜索 `LIMIT 50`、不判空 `endDate` 归一化到当日末
- [ ] 月份缓存 LRU 上限 3
- [ ] 积分允许负余额（无 `points >= ?` 条件）
- [ ] `isWord` 由「单词」标签勾选状态派生
- [ ] `completeTask` 返回值恒为 null（不要设计告警返回路径）