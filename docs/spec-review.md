# 规格核查报告 · spec-points-shop.md

> 核查对象：`docs/migration/spec-points-shop.md`（1021 行）
> 核查方式：逐条打开被引用的 Dart 文件，核对行号、SQL、行为；死代码结论用 grep 全仓验证
> 核查范围：A/B/C/D 四章 + G1–G14 + 对 `m1-decisions.md` 的工程风险挑刺
> **本报告只找错。规格写得对的地方一句话带过。**

---

## 1. 结论

**需修正后可用。**

不能直接照着实现。规格的**主干是对的**（表结构、SQL、事务边界、快照语义、颜色类型、name 分组、items.last 等我逐条验证均属实），但有 **3 类必须先修的问题**：

| 级别 | 问题 | 后果 |
|---|---|---|
| **P0 阻塞** | H1 裁决的「恢复时写回原 id」在 `recycled_tasks` 上**存在主键冲突与 `related_id` 二次错位**，且规格完全没提 | 按裁决实现会引入新的数据损坏 |
| **P0 阻塞** | 规格 D.8 的「6 个方法全部无调用方」**清单有错**（漏了 1 个活的、多算了 1 个死的） | RN 侧照着删活代码 → 数据导出功能坏掉 |
| **P1 必修** | G2/G4 结论正确但**引用的是死代码那一份**；规格多处把 `database_task_mixin.dart` 当权威，而生效路径是 `task_repository.dart` | 实现者按引用改会改错文件 |
| **P1 必修** | G1 说「7 种」但**表格列了 9 行**，且真正只写入 7 种——数量与表格自相矛盾，RN 侧会照抄 9 行 | 明细页类型映射写错 |
| **P2** | `settings` / `pomodoro_records` 两张表**零覆盖**；`pomodoro_records.related_task_id` 是第三个悬空引用，规格与裁决都没提 | 恢复任务后番茄钟记录错位 |

**核心判断：规格可以作为「参考」，不能作为「契约」。** 必须先按本报告 §3 修正，再交给 RN 侧实现。

---

## 2. 确认为真的部分（我实际打开文件验证过）

抽查 15 条，覆盖 A/B/C/D 四章。**以下全部属实，行号精确**：

| 规格位置 | 引用 | 核实结果 |
|---|---|---|
| A.2 原子加减 | `database_points_mixin.dart:40,50` | ✅ `points = points ± ? WHERE id = ?`，注释「避免丢失更新」在 :34 |
| A.2 `applyPointsDeltaTxn` | `database_points_mixin.dart:63` | ✅ 两分支逻辑、`requireAtLeast` 下推 `updated > 0` 全对 |
| A.2 分支 1 插 `delta` | 同上 :77 | ✅ `UserPoints(points: delta)`，默认 `id=1` |
| A.4 幂等查询② | `database_points_mixin.dart:159` | ✅ `orderBy: 'id DESC'` + 注释「不受时间戳精度影响」 |
| A.5 `markTaskDeducted` SQL | `database_task_mixin.dart:330` | ✅ `UPDATE tasks SET is_deducted = 1 WHERE id = ?`（**但这份是死代码**，见 §3.1） |
| A.6 `floor(reward/2)` | `task_settlement_mixin.dart:67` | ✅ 在 `if (deduct > 0)` 之前、循环体内 |
| A.7 不传 `requireAtLeast` | `points_provider.dart:74` → `database_points_mixin.dart:97` | ✅ 链路属实，**G4 结论正确** |
| A.3 `shop_purchase.related_id` | `database_purchase_mixin.dart:46-54` | ✅ 确实是 `shopItemId`（`shop_items.id`），**G1/H7 正确** |
| B.3 兑换四步事务 | `database_purchase_mixin.dart:27-69` | ✅ 步骤 A/B/C/D 逐字一致，含 `updated == 0 → return false` 回滚 |
| B.5 按 `name` 分组 | `warehouse_page.dart:28-34` | ✅ 分组键是 `item.name` |
| B.5 「使用」删 `items.last` | `warehouse_page.dart:170` | ✅ `_confirmDeleteOne(context, items.last, ...)`，而展示用 `firstItem`（:143,:151） |
| B.1.2 表空重播种 | `shop_provider.dart:36-39` | ✅ `if (existingItems.isEmpty)`，8 个商品价格/图标/颜色全对 |
| C.1 `INSERT OR IGNORE` | `database_tag_mixin.dart:40` | ✅ `ConflictAlgorithm.ignore` |
| C.3 删标签清 `task_tags` | `tag_provider.dart:50-55` | ✅ `deleteTag` + `deleteTaskTagsByTagId`，`firstWhere` 会抛 StateError |
| D.3 回收站裁剪 | `task_repository.dart:195-210` | ✅ `deleted_at DESC` + `skip(10)`，事务内 |

**G2 结论正确**：`database_task_mixin.dart:321` 与 `task_repository.dart:249` 都是 `DateTime(date.year, date.month, date.day)`，**无 `+1 day`**，变量名 `endOfDay` 是误导。今天到期不扣分，确认。

**G3 结论正确**：`points_page.dart:66-71` 确实硬编码 4 行（`'完成任务','+10'` 等），且全仓 `PointsPage` 只有定义处 2 个命中，零引用。

**G12 结论正确**：8 条索引逐条比对 `database_schema_mixin.dart:249-271` 与 `rn/src/db/schema.ts:146-153`，完全一致。

---

## 3. 确认有错的部分

### 3.1 【P0】D.8 / F13 死代码清单错误 —— 多算 1 个、漏算 1 个

**规格原文**（D.8 表格末行 + F13）：

> 死代码 | `lib/core/services/database/database_task_mixin.dart:205,244,257,263,305,314` | **6 个方法全部无调用方**

**代码实际情况**——我 grep 全仓（含 `data_export_page.dart`）后：

| 行号 | 方法 | 规格说 | 实际 |
|---|---|---|---|
| 205 | `moveTaskToRecycleBin` | 死 | ✅ 死（0 调用方） |
| 238 | `deleteTaskWithoutRecycle` | **规格没列** | 死（0 调用方）——**漏报** |
| 244 | `_cleanupRecycledTasksTxn` | 死 | ⚠️ **只在 :232 被同样是死代码的 `moveTaskToRecycleBin` 调用**，所以传递性死亡。算死没错，但它不是「无调用方」，是「只被死代码调用」 |
| **257** | **`getRecycledTasks`** | **死** | ❌ **活的**。`lib/modules/profile/pages/data_export_page.dart:300` 调用 `db.getRecycledTasks()`，其中 `db = DatabaseService.instance`（同文件 :272） |
| 263 | `restoreTaskFromRecycle` | 死 | ✅ 死 |
| 305 | `deleteFromRecycle` | 死 | ✅ 死 |
| 314 | `clearRecycleBin` | 死 | ✅ 死 |

**这意味着两件事**：

1. **RN 侧若按规格把 `getRecycledTasks` 当死代码删掉/不实现 → 数据导出页的「导出回收站」开关直接坏掉。** 这是规格会导致的功能缺失，不是风格问题。
2. 顺带暴露一个规格完全没提的功能：**数据导出页 `data_export_page.dart` 会读 `getRecycledTasks` / `getAllTags` / `getUserPoints` / `getAllShopItems` / `getAllPurchasedItems`** —— 这是一条规格与裁决都没覆盖的读路径。

**建议改法**：

```diff
- 死代码 | database_task_mixin.dart:205,244,257,263,305,314 | 6 个方法全部无调用方
+ 死代码 | database_task_mixin.dart:205,238,244,263,305,314 | 6 个方法无外部调用方
+          （244 仅被同为死代码的 :232 调用，属传递性死亡）
+ ⚠️ 反例：:257 getRecycledTasks **是活代码**，被 data_export_page.dart:300 调用（导出回收站）。
+          实现 RN 版时必须提供，否则数据导出功能缺失。
```

---

### 3.2 【P0】G1 数量与表格自相矛盾：说 7 种，表格列了 9 行

**规格原文**：A.3 标题「`points_records` —— **七种 type**」，表格列了 **9 行**（`task_complete`×2、`task_uncomplete`×2、`overdue_deduct`、`shop_purchase`、`scratch_cost`、`scratch_win`、`scratch_refund`）。G1 也说 7 种。

**代码实际情况**——我 grep 出全部写入点，去重后**正好 7 种**：

| type | 写入位置 | related_id |
|---|---|---|
| `task_complete` | `task_settlement_mixin.dart:35` / `task_crud_mixin.dart:147` | tasks.id |
| `task_uncomplete` | `task_settlement_mixin.dart:54` / `task_crud_mixin.dart:150` | tasks.id |
| `overdue_deduct` | `task_settlement_mixin.dart:72` | tasks.id |
| `shop_purchase` | `database_purchase_mixin.dart:50` | **shop_items.id** |
| `scratch_cost` | `database_purchase_mixin.dart:109` | **scratch_tickets.id** |
| `scratch_win` | `scratch_play_mixin.dart:204` | **null** |
| `scratch_refund` | `scratch_play_mixin.dart:226` | **null** |

**所以「7 种」是对的，表格按 type 去重后也该是 7 行。** 规格把「同 type 的两个调用来源」写成了 9 行，读起来像 9 种类型。RN 侧实现 `switch` 时若照抄表格结构，容易写出重复 case 或漏掉去重。

**另外规格有两处没写准**：

- A.3 表里 `scratch_win` / `scratch_refund` 的 `related_id` 写「待确认（§6）」。**§6 不存在**（本文档没有 §6）。实际已可确认：`scratch_play_mixin.dart:202-206` 与 `:224-228` 调 `addPointsWithRecord` 时**都没传 `relatedId`** → 落库为 **NULL**。规格把能确定的事写成了"待确认"。
- `scratch_refund` 的 `description` 实际固定为 `'刮刮乐退款'`（:227），A.3 表里只写「由刮奖流程传入」。

**建议改法**：表格按 type 去重成 7 行，另加一列「写入来源」区分小组件/UI 两个调用点；填上 `scratch_win`/`scratch_refund` 的 `related_id = NULL`；删掉不存在的「§6」引用。

---

### 3.3 【P1】G1/G2/G4 的证据引用指向死代码，且 A.5 的流程图 SQL 与生效实现不一致

规格 F13 明确说「`DatabaseTaskMixin` 的回收站方法是死代码，参考 `TaskRepository`」，**但 G2 和 A.5 的证据本身用的就是死代码那份**：

| 规格引用 | 该文件是否生效 | 生效的那份 |
|---|---|---|
| `database_task_mixin.dart:319` `getOverdueTasks`（G2、:163） | ❌ 死代码 | `task_repository.dart:247` |
| `database_task_mixin.dart:330` `markTaskDeducted`（A.5 :158） | ❌ 死代码 | `task_repository.dart:326` |
| `database_task_mixin.dart:215` `moveTaskToRecycleBin`（D.2 :663） | ❌ 死代码（这个引用是对的，它确实是死代码） | — |

`task_settlement_mixin.dart:61,79` 调的是 `_taskRepository.getOverdueTasks` / `_taskRepository.markTaskDeducted`，即 Repository 版本。

**好消息**：两份实现**语义完全相同**（我逐行比对，`task_repository.dart:247-256` 与 `database_task_mixin.dart:319-328` 字符级一致）。所以 **G2/G4 的结论不受影响**。

**但这暴露了一个规格方法论问题**：一份文档在同一节里既说「别参考这个文件」又拿这个文件当证据。实现者若只 follow 引用行号，会去改一个永远不执行的函数。

**建议改法**：G2 证据改为 `task_repository.dart:247-256`（并注明 `database_task_mixin.dart:319` 是等价死代码）；A.5 的 `markTaskDeducted` SQL 改引 `task_repository.dart:326-333`。

---

### 3.4 【P1】G2 把「今天到期」写对了，但 A.5 的流程图把 `WHERE` 条件写松了

**规格 A.5 流程图**写：

```
SELECT * FROM tasks
 WHERE cpl_time < ?
   AND is_ok = 0 AND is_deducted = 0 AND recurrence = 'none'
```

这与代码一致（`is_ok = ?` 传 `0`）。**这条没问题。**

真正的问题是 A.5 图里写「逐条循环：`if (task.isOK || task.isDeducted) continue`」，而代码 `task_settlement_mixin.dart:64` 的条件是：

```dart
if (taskId == null || task.isOK || task.isDeducted) continue;
```

**多了 `taskId == null`**。这个细节规格漏了。不影响正确性（`taskId` 为 null 时后面也用不了），但既然规格自称"逐行照搬"级别，应补。

---

### 3.5 【P2】`pomodoro_records.related_task_id` 是第三个悬空引用，规格与裁决都漏了

规格 D.4① 列了恢复后失效的引用，只有两个：`task_tags.task_id` 和 `points_records.related_id`。

**实际有三个**。`database_pomodoro_mixin.dart:48-58`：

```dart
Future<List<PomodoroRecord>> getPomodoroRecordsByTaskId(int taskId) async {
  ... where: 'related_task_id = ?' ...
}
```

`pomodoro_records` 表有 `related_task_id`（DDL `database_schema_mixin.dart:151`）和**标题快照** `related_task_title`。任务恢复后拿新 id → 番茄钟记录关联不上该任务。

**这一点对 H1 裁决是致命的**：裁决说「同步修正 `points_records.related_id` 与 `task_tags.task_id`」——**漏了 `pomodoro_records.related_task_id`**。按裁决实现，恢复任务后番茄钟历史会错位。修 H1 时必须一并处理。

（`related_task_title` 是快照，所以标题不会错，只是关联查不到。）

---

### 3.6 【P2】`custom_prize_pool` 两份 DDL 的疑点，规格说「需人工确认」，其实已经能确认

**规格 G14 / H9**：`createScratchTables` 的调用点需确认，哪份 DDL 权威。

**我已经确认了**：grep 全仓，`createScratchTables` **只有定义处一个命中，零调用方**。

- `database_scratch_mixin.dart:8` `Future<void> createScratchTables(...)` —— 定义
- 全仓无任何 `createScratchTables(...)` 调用

所以 `database_scratch_mixin.dart:10` 那份旧 DDL（`weight REAL DEFAULT 1.0` 无 NOT NULL）是**死代码**。权威 DDL 是 `database_schema_mixin.dart:100-107` 的严格版。`rn/src/db/schema.ts` 采用严格版是**对的**。

**H9 可以直接关闭**，不必延后到 M3。

**建议改法**：G14 与 H9 直接改为「已确认：`database_scratch_mixin.dart` 的 `createScratchTables` 零调用方，旧 DDL 为死代码；严格版（`database_schema_mixin.dart:100`）为权威」。

---

### 3.7 【P2】`clearPointsRecords()` 与 `addPointsRecord()` 的"无调用方"结论，我确认成立

规格 A.9 死代码表列了 `clearPointsRecords()`（:166）与 `addPointsRecord()`（:115）无调用方。这两条 grep 核实**属实**，可以照搬。

---

## 4. 规格没说但代码里有的行为（缺口）

### 4.1 【重要】批量删除会**逐条同步**进回收站，且每条都触发一次裁剪

`task_batch_mixin.dart:52-62`：

```dart
Future<String?> batchDeleteTasks() async {
  return _runBatch('删除', (taskId) async {
    await deleteTask(taskId);   // 无 deleteAll → 走回收站
    return true;
  });
}
```

**后果规格没写**：批量删 15 个任务 → 循环 15 次「插入 + 裁剪到 10」→ **前 5 个刚进回收站就被物理删除**。用户在批量删除后只会看到 10 条，且**没有任何提示**。这是「上限 10 条」这个设计最反直觉的表现，规格 D.3 只讲了「只在移入新任务时裁剪」，没讲批量场景下的即时生效。

RN 侧照搬时，批量删除必须确认：裁剪逻辑是在同一事务内逐条跑（照搬），还是先收集后统一裁剪（行为不同）。**照搬的结果是用户会丢任务**。

### 4.2 数据导出页是规格完全没提的读路径

`data_export_page.dart:272-302` 会读 `getRecycledTasks` / `getAllTags` / `getUserPoints` / `getAllShopItems` / `getAllPurchasedItems`，并按用户勾选的开关打包成 JSON（文件名 `noteapp_export_*.json`，注意前缀是 `noteapp` 不是 `v5`）。

规格 E 章「界面行为清单」里没有这一页，`m1-decisions.md` 也没提它。M1 若不实现，导出功能消失；若实现，必须包含 `recycled_tasks`（因为 §3.1 已证明那个方法不是死代码）。

### 4.3 `PRAGMA foreign_keys` 从未开启 —— 规格只在 schema-v3 里提，规格正文没提

grep 全仓，`lib/` 下唯一的 `PRAGMA` 是 `database_migration_mixin.dart:50` 的 `PRAGMA table_info(recycled_tasks)`。**没有任何 `foreign_keys = ON`**。

所以 `task_tags` 声明的 `ON DELETE CASCADE`（`database_schema_mixin.dart:138-139`）**确定不生效**。规格 C.3 的结论（删任务产生孤儿）正确，但**没有把"外键未启用"作为根因写进规格**，读者可能以为 cascade 只是"大概率没生效"。schema-v3 §2.3 写对了，规格应同步。

### 4.4 `_shouldHandlePoints` 的双重防线在 A.5 图里被简化掉了

`task_settlement_mixin.dart:11-14` 有一个独立方法 `_shouldHandlePoints`，它内部**又检查了一遍** `task.id == null || task.rewardPoints <= 0`，而调用方 `_checkOverdueTasks` 在 `:65` 已经检查过 `rewardPoints <= 0`。规格 A.5 的流程图只画了调用方那次检查。这是冗余防御，不是 bug，但规格说"这是全模块最需要精确复刻的逻辑"却漏画了。

### 4.5 逾期扣分**不写** `task_id` 之外的关联，规格没漏但也没点明

`overdue_deduct` 的 `related_id = tasks.id`（`task_settlement_mixin.dart:74`），与 `task_complete`/`task_uncomplete` 同表。**这意味着**：恢复任务后（拿新 id），`overdue_deduct` 流水也一起悬空 → 恢复 → 再逾期 → 会**再扣一次分**。规格 D.4① 提到了 `getLatestPointsRecord` 受影响，但没把 `overdue_deduct` 的重复扣分单独点出来（它走的是 `hasPointsRecordByTypeAndRelatedId`，是另一个查询）。**这是 H1 必须修的第三个点，且比重复加分更隐蔽。**

---

## 5. 对 `m1-decisions.md` 的反对意见

### 5.1 【反对】H1「恢复时写回原 id」会撞 `sqlite_sequence`，且裁决的「必然不存在」前提不成立

裁决第 27 行写：

> **实现注意**：原 id 在 `tasks` 中必然不存在（`AUTOINCREMENT` 保证不复用），所以带 id 插入不会主键冲突。

**这个推理有一个漏洞**：`AUTOINCREMENT` 保证的是「自动分配时不复用已删除 id」。但它**不保证**你**显式插入**一个已被占用的 id 不冲突——显式插入直接走主键约束，撞了就是 `UNIQUE constraint failed: tasks.id`。

**更关键的问题：裁决自己要求「若插入时真的撞了，必须回滚事务并提示，绝不能静默换 id」。但在当前代码结构下，这是必然发生的情况，不是理论情况：**

**同一任务被删两次的场景**（裁决直接点名要我验证）：

```
1. 任务 A (id=5) 被删 → recycled_tasks 行 R1 (task_id=5, loop_id=L)
2. 用户从回收站「仅恢复当天」→ recycle_bin_page.dart:232-234
   → deleteFromRecycle(R1) 删除 R1
   → addTask(task.copyWith(recurrence:'none'))  ← 注意：这里走的是 addTask，不是 restoreTaskFromRecycle
   → 走 TaskRepositoryImpl.addTask → _insertTaskIfNotExists → db.insert('tasks', task.toMap())
   → Task.toMap() 不含 'id'（task_model.dart:69-84）→ SQLite 自动分配新 id，比如 12
3. 任务 A 现在是 id=12
4. 用户又删一次 A → recycled_tasks 行 R2 (task_id=12)
```

**此时 R1 已删除，R2 的 task_id=12** —— 所以单一路径下不会撞。

**但真正的撞车场景是「仅恢复当天」+ H1 混用**：裁决 H1 只改了 `restoreTaskFromRecycle` 走写回原 id，**没管 `recycle_bin_page.dart:232` 的「仅恢复当天」分支**。这条分支是「先删回收站行，再 `addTask` 新建」，`addTask` 走 `db.insert` 不带 id → **新 id**。于是同一个任务可能同时存在两条路径产生两个 id，写回原 id 时其中一条必然撞。

**结论**：H1 的方向对（恢复时保持 id 确实能同时修好加分重复和标签丢失），但**实现范围不完整**。「仅恢复当天」分支必须一并处理，否则裁决声称的「用户无法再利用刷分」**不成立** —— 用户改用「仅恢复当天」按钮即可绕过。

**建议**：
- H1 补一条：「仅恢复当天」分支也必须写回原 id（或至少让裁决明确接受该分支仍可刷分）。
- 恢复流程里对 `tasks.id` 做显式存在性检查，撞了就回滚 + 提示（裁决已要求，但需确认有这条 SQL）。
- **不要依赖 AUTOINCREMENT 作为「不冲突」的保证**，那是不相关的不变量。

### 5.2 【反对】H1 只列了两个表，漏了 `pomodoro_records` 和 `overdue_deduct`

裁决第 25 行：

> 并同步修正 `points_records.related_id` 与 `task_tags.task_id`。

漏了两处：
1. **`pomodoro_records.related_task_id`**（§3.5）—— 恢复后番茄钟记录关联丢失。
2. **`points_records` 里 `type='overdue_deduct'` 的行**（§4.5）—— 若只按 `type IN ('task_complete','task_uncomplete')` 过滤修正，逾期扣分流水会留在旧 id 上，恢复后再次逾期会**重复扣分**（而且因为允许负余额，用户余额会真的变负）。

建议修正语句的 WHERE 条件覆盖**全部 3 个 task 相关 type**：
```sql
UPDATE points_records SET related_id = :newId
WHERE related_id = :oldId
  AND type IN ('task_complete','task_uncomplete','overdue_deduct')
```

### 5.3 【反对】H4 的 `purgeOrphanTaskTags()` 定义在恢复流程中**不会误删**，但有一个启动时序风险

裁决第 49 行定义：`tasks` 和 `recycled_tasks` 里都查不到才算孤儿。

**我验证了这个定义在恢复流程中是安全的** —— 因为 `recycled_tasks` 保留了 `task_id`，只要任务还在回收站，`task_tags` 的行就不会被判为孤儿。这正是裁决的设计意图，**逻辑正确**。

**但有一个规格没提、裁决也没覆盖的风险**：清理如果在**恢复之后**跑，而不是启动时跑，会误删。举例：

```
1. 任务 A (id=5) 删除 → R1(task_id=5)
2. 用户恢复 A → tasks 重新有 id=5（若采纳 H1）→ R1 删除
3. 此时 task_tags 里 task_id=5 的行是有效关联 → 不会被删 ✅
```

这条链在 H1 成立时是自洽的。但如果 **H1 与 H4 的实现顺序反了**（先清孤儿、后恢复），或者恢复时 H1 没生效（走了「仅恢复当天」新 id 路径），那么：

```
1. 任务 A (id=5) 删除 → R1(task_id=5)
2. 「仅恢复当天」→ 删 R1 → 新建 id=12
3. 启动清理：task_id=5 在 tasks 和 recycled_tasks 都查不到 → **删掉 A 的标签关联**
4. 用户发现：任务恢复了，但标签全没了，而且**永久无法恢复**
```

**这比"标签不恢复"严重**——原本 H4 的目的是"保住恢复能力"，但在「仅恢复当天」路径下它反而**提前销毁**了恢复能力。

**建议**：H4 的启动清理必须**排除**「曾进过回收站」的 id。可行做法是清理时也把 `recycled_tasks.task_id` 纳入白名单（裁决已包含），但要额外确认：**「仅恢复当天」分支也要把 `task_id` 写进 `tasks` 的 id**，否则第 3 步的清理仍会误删。这条与 5.1 是同一个根因。

### 5.4 【附议但要补】H4 说会让 `verifyGolden` 行数检查漂移 —— 补一个规格没提的风险

裁决第 51-52 行说验收 SQL 要从「行数=固定值」改成「孤儿数=0」。

**补充**：改成「孤儿数=0」后，`schema-v3.md §7` 第 3 条验收查询本身也要改 —— 它现在的定义是「`task_tags` LEFT JOIN `tasks` WHERE `tasks.id IS NULL`」，这**会把回收站里任务的标签关联算成孤儿**（因为任务已从 `tasks` 移除）。所以：

- 迁移前后对比时，Flutter 旧库的「孤儿数」必然 > 0（回收站任务的所有标签）
- RN 新库若照 H1 恢复过任务，孤儿数会不同
- **两库「孤儿数=0」永远不成立**

正确的验收口径应该是「孤儿数 = 两边一致」或「`task_tags` 中 `task_id` 同时不在 `tasks` 和 `recycled_tasks` 的行数为 0」。裁决只说了改行数检查，**漏了第 3 条孤儿检查的口径**。

---

## 6. 我不确定的地方

### 6.1 `sqlite_sequence` 在显式插入 id 后的行为，我是推理的，未实测

§5.1 里我推断「显式插入带 id 时，SQLite 会把 `sqlite_sequence` 至少设为该 id」。我**没有在真机/模拟器上实测**这一点（本次核查不跑构建）。

- 若成立：写回 id=5 后序列仍 ≥ 5，后续新增任务拿 6+，不撞。
- 若不成立（序列保持原值）：也不影响正确性，因为 `AUTOINCREMENT` 会保证新分配的 id 大于所有已用 id。
- **但有一种情况我无法排除**：如果实现里同时有「显式写回 id」和「另一条路径显式指定 id」的写入，序列可能被顶高，导致后续 id 出现空洞。**空洞本身无害**，但如果 RN 侧有任何「id 连续」的假设就会出问题。我没找到这样的假设。

**建议**：实现后跑一次真机回归：删除→恢复→新增，确认 id 不冲突。

### 6.2 `recycled_tasks.id` 冲突问题，团队-lead 问的「同一任务被删两次」，我的结论依赖 H1 是否实施

团队-lead 问：`id 在 recycled_tasks 里会不会冲突？`

**答：`recycled_tasks.id` 本身不会冲突**（`INTEGER PRIMARY KEY AUTOINCREMENT`，`database_schema_mixin.dart:81`），每次插入新分配。规格 D.2 这一点写得对。

**但「同一任务被删两次」会产生两个 `task_id` 相同的回收站行吗？** 我推演下来**不会**，因为：
- 「仅恢复当天」分支会先 `deleteFromRecycle` 再 `addTask`，回收站行被删掉了
- 「恢复循环」分支恢复后任务回到 `tasks`，再删会插新行，但 `task_id` 是新 id

**唯一能产生重复 `task_id` 的路径是「清空回收站失败但删除成功」这类部分失败**，我没能构造出确定成立的场景。**这条我标注为「不确定，但倾向于不会」。**

**裁剪到 10 条时被物理删除的记录，其 `related_id` 怎么办？**（团队-lead 问的第三点）

- 回收站行被裁剪物理删除时，**代码不做任何连带处理**（`task_repository.dart:202-208` 只有一条 `DELETE FROM recycled_tasks`）
- 所以：若该任务曾在回收站里被永久删除/被裁剪，其 `points_records`（若有 `task_complete` 流水）**永久悬空**，且**永久无法恢复** —— 因为 `recycled_tasks.task_id` 这个「唯一线索」（规格 D.4③ 的说法）已经没了
- **规格完全没提这条**。它意味着 D.4③ 「`task_id` 是唯一能找回原 id 的线索」这句话**有前提**：该行还在回收站里。裁剪会消灭这个前提
- 这也意味着：**裁剪是唯一会造成 `points_records` 永久悬空的操作**，而 H1 的修复只能救「还在回收站里」的任务。**H1 修不了裁剪造成的损失**

### 6.3 `overdue_deduct` 重复扣分，我没有找到 RN 侧的对应实现来确认影响面

§4.5 说的「恢复后再次逾期会重复扣分」，我确认了 Flutter 侧的机制（`hasPointsRecordByTypeAndRelatedId` 用 `related_id` 查，重 id 查不到 → 重复扣）。但 `rn/src/core/points.ts` 的 `resolveOverdueDeduction` 是**纯函数**，输入是 `hasOverdueRecord: boolean`，不碰 DB —— 所以**实际是否重复取决于调用方怎么算这个 boolean**，而调用方代码还不存在。**这个风险在 RN 侧尚未落地，但一旦照 §5.2 修好 related_id，它会自动消失。** 我无法确认调用方会怎么写。

### 6.4 `points_page.dart` 的死代码判定我有 95% 把握，不是 100%

grep `PointsPage` 只有定义处 2 个命中。但**我没有检查是否有 `routes.dart` 之外的动态路由**（比如 `go_router` 的字符串路由表、或 `onGenerateRoute`）。我 grep 了 `app_router.dart` 的 `recycleBin` 分支（规格 D.8 提到了），确认它用常量字符串。但**是否存在运行时按字符串拼接的路由**，我没查。**如果存在，`PointsPage` 可能是活的。** 概率很低（Flutter 项目里这种写法少见且 `PointsPage` 无参数），但我没有 100% 排除。

### 6.5 我没有验证 RN 侧 `schema.ts` 的 DDL 是否真的与 Flutter 逐列一致

G13 说「唯一差异：`SEED_SQL` 用 `INSERT OR IGNORE` 且不插示例任务」。我确认了 Flutter 侧 `_insertSampleTasks`（`database_schema_mixin.dart:197-244`）确实插 3 条，标题为「欢迎使用任务管家」「查看使用说明」「试试下拉菜单」。**我没有逐列比对 `rn/src/db/schema.ts` 的全部 DDL**（只比对了 8 条索引）。G13 的「逐列一致」结论我**未独立验证**，只验证了它指出的那一处差异确实存在。

---

## 7. 修正清单（按优先级，交给规格作者）

| # | 位置 | 动作 |
|---|---|---|
| 1 | D.8 / F13 | 死代码清单改为 `205,238,244,263,305,314`；**新增警告：`getRecycledTasks`（:257）是活代码**，被 `data_export_page.dart:300` 调用 |
| 2 | A.3 | 9 行去重为 7 行 type；填 `scratch_win`/`scratch_refund` 的 `related_id = NULL`；删除不存在的「§6」引用 |
| 3 | G2 / A.5 | 证据行号从 `database_task_mixin.dart` 改为 `task_repository.dart:247` / `:326`（注明前者是等价死代码） |
| 4 | A.5 图 | 补 `taskId == null` 这一条 continue 条件 |
| 5 | D.4① | 新增第三/第四个悬空引用：`pomodoro_records.related_task_id`、`overdue_deduct` 流水 |
| 6 | D.3 / 4.1 | 新增「批量删除逐条同步入回收站，每条触发裁剪 → 批量删 15 个会即时丢 5 个」的行为说明 |
| 7 | C.3 | 补根因：「`PRAGMA foreign_keys` 全仓从未开启」→ cascade 确定性失效（非「大概率」） |
| 8 | G14 / H9 | 改为已确认：`createScratchTables` 零调用方，旧 DDL 是死代码，严格版权威，H9 可关闭 |
| 9 | E 章 | 补「我的 → 数据导出」页面的读路径（5 个 DB 方法） |
| 10 | 全文 | `settings`（0 提及）、`pomodoro_records`（0 提及）两张表需明确标注「不在本文范围」或补覆盖 |

---

## 8. 给 RN 侧的一句话

**在 §3.1 的死代码清单和 §5.1 的 H1 范围问题修正前，不要开始实现积分/回收站模块。** 其余部分（表结构、事务 SQL、快照语义、颜色类型、分组规则、裁剪上限）可以照搬。