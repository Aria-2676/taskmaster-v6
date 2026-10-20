# 行为规格 · 积分 / 商城 / 标签 / 回收站（M1 后四模块）

> 用途：Flutter → React Native 换栈的 **1:1 行为重写**依据。任务模块（`lib/modules/tasks/`）由 general-purpose-1 负责（产物 `docs/migration/spec-tasks.md`），本文只在必要处标注依赖点。
> 来源：`lib/modules/{points,shop,tag}/`、`lib/providers/{points,shop,tag}_provider.dart`、`lib/core/services/database/database_{points,shop,tag,purchase,task}_mixin.dart`、`lib/modules/tasks/repositories/task_repository.dart`（回收站实际实现所在）。
> 配套：`docs/migration/schema-v3.md`（数据契约）、`docs/migration/business-rules.md`（业务规则）、`rn/src/core/points.ts`（已实现的结算纯函数）。
> **裁决原则：代码为准。** 本文 §G 逐条列出代码与文档不一致处。

### 修订来源（ traceability）

本文经两轮外部核查修正，**每条修正的来源必须可追溯**：

| 来源 | 任务 | 贡献 |
|---|---|---|
| `docs/migration/spec-review.md`（作者 **software-qa-engineer-1**） | #14 独立核查 | 指出 2 条 P0（死代码清单把 `getRecycledTasks` 误判为死代码、A.3 说 7 种却列 9 行）+ 3 条 P1 + 5 条 P2。**本文第 3.1/3.2/3.3/3.5/3.6/4.1 节即按此修正** |
| 与 **general-purpose-1** 的交叉核对 | — | ① 循环回补**不扣积分**（F13a）② `overdue_deduct` 双查询 → **V5 定为实现红线**（G4b/X1b，定级经三次修正）③ 回收站裁剪会消灭修复线索（X1c）④ `DatabaseTaskMixin` 读写侧精确边界（X6）⑤ §7 需改**两条**（X4） |
| 与 **team-lead 裁决**（`m1-decisions.md` 第五轮 V1–V5） | — | **V1 补充**：孤儿清理补齐四条永久删除路径（我提的 `deleteAll` 缺口 + 他补的 `deleteFromRecycle`），并要求 `deleteAll` 分支**新引入事务**；**V3** C.3/F14/X3 措辞改为「不立即清理」并写明「谁在何时清理」；**V4** H2 改为**有条件自动恢复**；**V5** G4b 改为实现红线 |
| 与 **software-qa-engineer-1** 结论的**分歧**（已实测裁决） | — | review §3.1 称两个 `getRecycledTasks`「返回字段 5 vs 10」——**实测不成立**，SQL 字符级相同、均 15 字段。review 的结论对，理由错。详见 D.8 注 |

> ⚠️ **交叉核对的结论曾被误记归属**：上述第 ②–⑤ 条曾一度被标注为「general-purpose-1 的 review」，实际 `spec-review.md` 的作者是 software-qa-engineer-1（任务 #14），general-purpose-1 从未写过 review。已修正。

---

## 0. 阅读指引：四条最容易踩的「不看代码绝对猜不到」

| # | 事实 | 影响 |
|---|---|---|
| **G1** | `points_records.type` 实际有 **7 种**，不是文档写的 5 种。多出 `shop_purchase`（商城兑换）与 `scratch_cost`（刮刮乐购票）。 | 明细页要能渲染这两种；统计口径要包含它们 |
| **G2** | `recycled_tasks` **只保留最近 10 条**。每次移入回收站后在同一事务内裁剪，旧的直接物理删除。**不是按时间过期，是按条数上限。** | 「保留多久」= 无时间概念，最多 10 条 |
| **G3** | `lib/modules/points/pages/points_page.dart` **整页是硬编码假数据**（`'完成任务', '+10'` 等 4 行写死），且**没有任何地方引用它**。`PointsRecordPage` 存在**两份同名类**，真正被使用的是 `lib/modules/profile/pages/profile_page.dart` 里内嵌的那份，`modules/points/pages/` 下那份是死代码。 | RN 侧**不要**照抄 `points_page.dart` |
| **G4b** | 🔴 **实现红线（非缺陷）**：修复 H1 时**绝不能把 `is_deducted` 置 0**。逾期扣分与完成结算走**两条完全独立的查询**（除 `related_id` 外无交集），且逾期扣分**不校验余额** | 置 0 → 两道门同时失效 → **真扣钱、余额无下限**。当前 Flutter / RN 两侧**均未触发**，需持续保持。详见 G4b 专节 |

---

## A. 积分（points）

### A.1 `user_points` —— 单行表，恒为 `id = 1`

DDL（`database_schema_mixin.dart:41`）：

```sql
CREATE TABLE IF NOT EXISTS user_points (
  id INTEGER PRIMARY KEY DEFAULT 1,   -- 注意：没有 AUTOINCREMENT，也没有 CHECK(id=1)
  points INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
```

> ⚠️ 与 `pomodoro_settings` 不同，`user_points` **没有 `CHECK (id = 1)`**（对比 `database_schema_mixin.dart:160`）。单行性靠**代码约定**保证，不是数据库约束。RN 侧建议加 `CHECK` 或至少在 Repository 层断言。

**懒初始化**（`database_points_mixin.dart:7` `getUserPoints`）：查不到行时插入一行 `points = 0` 并返回。这是**唯一**的建行入口——所有写积分的方法都先调 `getUserPoints()` 保证行存在（`addPoints` / `deductPoints` / `applyPointsDeltaTxn` 都会先调）。

**首次建库时**由 `_createDB` 末尾插一行（`database_schema_mixin.dart:187`），所以正常路径不会走懒初始化。

### A.2 余额的读与写

| 场景 | API | 实际 SQL |
|---|---|---|
| 读余额 | `getUserPoints()` | `SELECT * FROM user_points WHERE id = ? LIMIT 1`（`id=1`）；空则 `INSERT` 默认行 |
| 覆盖写 | `updateUserPoints(int)` | `UPDATE user_points SET points = ?, updated_at = ? WHERE id = ?` |
| 原子加 | `addPoints(int)` | `UPDATE user_points SET points = points + ?, updated_at = ? WHERE id = ?` |
| 原子减 | `deductPoints(int)` | `UPDATE user_points SET points = points - ?, updated_at = ? WHERE id = ?` |
| 事务内增减 | `applyPointsDeltaTxn(txn, delta, {requireAtLeast})` | 见下 |

**并发处理**：注释（`database_points_mixin.dart:32`）明确说 `addPoints`/`deductPoints` 改成 `points = points ± ?` 的原子 SQL，是为了避免「先读余额、算好再写回」的**丢失更新**。RN 侧必须照做，**不要**读出来在 JS 里算。

**`applyPointsDeltaTxn` 的两个分支**（`database_points_mixin.dart:63`）——这是全模块最需要精确复刻的逻辑：

```dart
// 分支 1：行不存在
if (existing.isEmpty) {
  if (requireAtLeast != null && requireAtLeast > 0) return false;  // 要求余额 → 直接失败
  await txn.insert('user_points', UserPoints(points: delta).toMap());  // 否则插入，余额 = delta
  return true;
}
// 分支 2：行存在
final where = requireAtLeast == null ? 'id = ?' : 'id = ? AND points >= ?';
final updated = await txn.rawUpdate(
  'UPDATE user_points SET points = points + ?, updated_at = ? WHERE $where',
  [delta, nowIso(), 1, ?requireAtLeast],
);
return updated > 0;
```

> 🔍 **不看代码绝对猜不到**：分支 1 插入时余额是 `delta` 而不是 `delta + 0`——看起来一样，但 `UserPoints(points: delta)` 的默认 `id = 1`，所以插入的是 `(1, delta, now)`。而 `purchaseShopItem` 里同一个位置插的是 `UserPoints()` 即 `(1, 0, now)`，**然后再 UPDATE**。两处行为等价但路径不同，RN 侧统一成「先确保行存在再 UPDATE」即可。

**`requireAtLeast` 的语义**：把「余额不足」下推到 SQL 的 `WHERE points >= ?`，靠 `updated > 0` 判断成败，**避免读-改-写竞态**。RN 侧必须用同样的 `WHERE` 判定，不能先 `SELECT points` 再判断。

### A.3 `points_records` —— 七种 type

`business-rules.md §3.3` 只列了 5 种。代码里实际写入的是 **7 种**：

| type | 何时写入 | `points` 符号 | `related_id` 指向 | `description` | 写入位置 |
|---|---|---|---|---|---|
| `task_complete` | 任务标记完成且未加分 | **正** `+rewardPoints` | `tasks.id` | `完成任务: <title>` | `task_settlement_mixin.dart:35` |
| `task_uncomplete` | 取消完成且最近流水是加分 | **负** `-latest.points` | `tasks.id` | `取消完成: <title>` | `task_settlement_mixin.dart:54` |
| `overdue_deduct` | 启动时扫描逾期任务 | **负** `-(rewardPoints/2).floor()` | `tasks.id` | `逾期任务扣除: <title>` | `task_settlement_mixin.dart:72` |
| **`shop_purchase`** | 商城兑换成功 | **负** `-price` | **`shop_items.id`** | `购买商品: <商品name>` | `database_purchase_mixin.dart:50` |
| **`scratch_cost`** | 刮刮乐购票成功 | **负** `-cost` | **`scratch_tickets.id`** | `购买刮刮卡`（固定文案） | `database_purchase_mixin.dart:109` |
| `scratch_win` | 刮刮乐中奖（非 goods 型） | **正** `+prizeValue` | **`NULL`** | `刮刮乐中奖: <prizeName>` | `scratch_play_mixin.dart:202` |
| `scratch_refund` | 刮刮乐发奖失败退款 | **正** `+costPoints` | **`NULL`** | `刮刮乐退款`（固定文案） | `scratch_play_mixin.dart:225` |

**恰好 7 种**（上面 7 行）。RN 侧实现明细页 `switch` 时就是这 7 个 case。

**同一 type 有两个调用来源**（不影响 type 数量，只影响 `description` 文案）：

| type | 触发来源 | `description` | 位置 |
|---|---|---|---|
| `task_complete` | 应用内 UI | `完成任务: <title>` | `task_settlement_mixin.dart:35` |
| `task_complete` | 桌面小组件 | `完成任务(小组件): <title>` | `task_crud_mixin.dart:147` |
| `task_uncomplete` | 应用内 UI | `取消完成: <title>` | `task_settlement_mixin.dart:54` |
| `task_uncomplete` | 桌面小组件 | `取消完成(小组件): <title>` | `task_crud_mixin.dart:150` |

> 🔍 **不看代码绝对猜不到**：`shop_purchase` 的 `related_id` 指向 **`shop_items.id`**，不是 `purchased_items.id`。同一笔兑换在 `purchased_items` 和 `points_records` 里用的是**同一个数字，但语义是不同表的主键**。对账时不要拿 `related_id` 去 join `purchased_items`。
>
> 🔍 **`scratch_win` / `scratch_refund` 的 `related_id` 是 `NULL`**，不是指向票据。`scratch_play_mixin.dart:202` 与 `:225` 调 `addPointsWithRecord` 时**都没传 `relatedId`** 参数 → 落库为 NULL。**所以 `business-rules.md §3.3` 说的「刮刮乐类 → `scratch_tickets.id` 或奖池 id」只对 `scratch_cost` 成立，对 `scratch_win` / `scratch_refund` 是错的。**
>
> 这也意味着：**刮刮乐的每一次中奖/退款都无法通过 `related_id` 追溯到具体票据**，只能按时间顺序推断。这是已知的信息缺失，不是可修的 bug（历史数据里 `related_id` 就是 NULL）。

**`points` 字段永远带符号**，明细页直接靠 `points > 0` 判断收支（`points_record_page.dart:120`），不做绝对值处理。

### A.4 幂等性：靠「先查后写」，**没有唯一索引**

`points_records` 的 DDL（`database_schema_mixin.dart:49`）只有 `id INTEGER PRIMARY KEY AUTOINCREMENT`，索引也只有**非唯一**的 `idx_points_records_type_related ON points_records(type, related_id)`（`database_schema_mixin.dart:264`）。

> ⚠️ **没有 `UNIQUE(type, related_id)`**。所以幂等**完全靠应用层先查后写**，两个并发写可以穿透。RN 侧照搬即可（保持行为一致），但要知道这是**已知的弱幂等**，不是数据库保证。

三种幂等查询，对应三种语义：

```sql
-- ① 「这个 type + related_id 有没有出现过」—— 逾期扣分用
SELECT 1 FROM points_records WHERE type = ? AND related_id = ? LIMIT 1;

-- ② 「取最近一条结算流水」—— 完成/取消完成用
--    按【自增主键】倒序，不按时间戳（注释：不受时间戳精度影响）
SELECT * FROM points_records
 WHERE related_id = ? AND type IN (?, ?)
 ORDER BY id DESC
 LIMIT 1;
```

**任务结算的幂等规则**（`task_settlement_mixin.dart`）：

| 动作 | 判定 | 金额来源 |
|---|---|---|
| 加分（完成） | 取最近一条 `type IN ('task_complete','task_uncomplete')`；**若它是 `task_complete` 则不加**，否则加 | 任务当前 `rewardPoints` |
| 冲销（取消完成） | 取最近一条同集合流水；**必须是 `task_complete`**，否则不动 | **那条流水的 `points`**，不是任务当前 `rewardPoints` |

> 🔍 **不看代码绝对猜不到**：冲销金额取的是**历史流水里的值**。任务完成期间把 `rewardPoints` 从 10 改成 50，再取消完成，退的是 **10** 不是 50。这保证了加减对称。RN 侧 `resolveUncompletion()`（`rn/src/core/points.ts:44`）已经用 `latestSettlementPoints` 表达了这一点，**直接复用**。

> 前置条件：`task.id != null && task.rewardPoints > 0`（`task_settlement_mixin.dart:12,28`）。`rewardPoints <= 0` 的任务**完全不写流水**。

### A.5 顺序敏感的三处 —— 逐处展开

`business-rules.md §5` 列了三处但没展开。以下是代码级的精确展开：

#### ① 逾期扣分：先扣分，后置 `is_deducted`

`task_settlement_mixin.dart:60` `_checkOverdueTasks()` 完整流程：

```
触发时机：TaskProvider.initialize()（task_provider.dart），即每次冷启动
  ↓
SELECT * FROM tasks
 WHERE cpl_time < ?      -- 今天 00:00（注意：见下方注）
   AND is_ok = 0
   AND is_deducted = 0
   AND recurrence = 'none'
  ↓
逐条循环：
  if (task.isOK || task.isDeducted) continue      -- 二次防线
  if (task.rewardPoints <= 0) continue
  deduct = floor(task.rewardPoints / 2)           -- 取整在这里，见 A.6
  if (deduct > 0 && 不存在 overdue_deduct 流水) {
      deductPointsWithRecord(points: deduct, type: 'overdue_deduct', ...)
  }
  await markTaskDeducted(task.id)                 -- ★ 无条件执行，即使上面没扣
```

**顺序错了会怎样**：若先 `markTaskDeducted` 再扣分，一旦扣分抛异常（磁盘满、DB 锁），`is_deducted` 已置 1，下次启动该任务被 `WHERE is_deducted = 0` 直接过滤掉 → **该任务永久漏扣，余额与预期永久偏差**。代码注释（`task_settlement_mixin.dart:77`）明写这条。

> 🔍 **不看代码绝对猜不到**：`markTaskDeducted` 在 `if (deduct > 0)` 块**外面**，是**无条件**执行的。后果：`rewardPoints = 1` 的任务，`floor(1/2) = 0` → 不扣分，但 `is_deducted` 被置 1。之后若用户把奖励改成 100，这条任务**永远不会**再被扣分。`rewardPoints = 0` 的任务则被上一行 `continue` 挡住，不置位。
>
> ⚠️ `floor(x/2)` 的结果为 0 只在 `rewardPoints = 1` 时发生（`rewardPoints <= 0` 已被挡）。所以这是一个**极窄但真实**的边界。RN 侧建议**照搬**（保持行为一致），但要在代码里留注释说明这是有意复刻的缺陷。

**`markTaskDeducted` 的 SQL**（生效路径 `task_repository.dart:326`）：
```sql
UPDATE tasks SET is_deducted = 1 WHERE id = ?;
```
> ℹ️ `database_task_mixin.dart:330` 有字符级相同的等价实现，但那是**死代码**（见 D.8）。`task_settlement_mixin.dart:79` 调的是 `_taskRepository.markTaskDeducted`，即生效的那份。

> ⚠️ **代码与文档不一致**：`getOverdueTasks`（生效路径 **`task_repository.dart:247`**）的过期判定是 `cpl_time < 今天 00:00`，**不含今天**。变量名叫 `endOfDay` 但实际是**当天零点**（`DateTime(date.year, date.month, date.day)`，无 `+1 day`）。所以「今天到期但没完成」的任务**不会被扣分**，要等到明天启动。`business-rules.md §1.3` 写的条件是 `cpl_time < now`，**不准确**。以代码为准。
> ℹ️ `database_task_mixin.dart:319` 是**死代码**的等价实现（逐行比对语义完全相同），本节统一引生效路径。

#### ② 商城兑换：同事务扣分 + 写流水 + 写快照

见 §B.3。

#### ③ 循环任务：先查同日重复，再插入

属 tasks 模块，仅标注依赖：恢复循环任务时 `task_recycle_mixin.dart:15` 会调 `_taskSchedulerService.generateRecurringTasks(restoredTask.copyWith(cplTime: originalCplTime))`。

### A.6 `floor(reward/2)` 的取整位置

```dart
final int deductPoints = (task.rewardPoints / 2).floor();   // Dart：先转 double 再 floor
```

- 发生在 **循环体内、`if (deduct > 0)` 判定之前**，即「先算、再决定扣不扣」。
- RN 侧对应 `Math.floor(rewardPoints / 2)`，`rn/src/core/points.ts:75` 已实现。
- 因为是 `double` 除法再 `floor`，大数不会溢出（`rewardPoints` 是 int，除法提升为 double）。
- 结果 ≤ 0 → 不扣分、不写流水、但仍置 `is_deducted`（见 A.5①）。

### A.7 逾期扣分是否允许余额为负

`business-rules.md §6` 待核实第 1 条。**代码给出了答案**：

`applyPointsChange(delta: -deduct, ...)` 调用时**没有传 `requireAtLeast`**（`task_settlement_mixin.dart:70` → `points_provider.dart:74` → `database_points_mixin.dart:97`）。`requireAtLeast` 为 `null` 时 `where = 'id = ?'`，**不校验余额**。

> ✅ **结论：逾期扣分允许余额为负。** 余额可以扣成负数，代码不拦截。
> RN 侧**不要**加「余额不足则跳过」的逻辑——那会导致 `is_deducted` 已置位但没扣分，或反之。

对比：`shop_purchase` / `scratch_cost` **传了** `requireAtLeast`（等价于 `WHERE points >= price`），余额不足则整笔回滚。**同一套 API，两种语义**，实现时务必区分。

### A.8 积分明细页展示什么

**实际生效的页面**是 `lib/modules/profile/pages/profile_page.dart` 内嵌的 `PointsRecordPage`（从「我的」页 → `我的积分` 进入）。**`lib/modules/points/pages/points_record_page.dart` 是死代码**（`app_router.dart` 无路由，`profile_page.dart` 未 import 它）。

| 区域 | 内容 | 数据来源 |
|---|---|---|
| 顶部卡片 | 「当前积分」+ 数值，琥珀渐变底 | `PointsProvider.currentPoints` |
| 列表 | 每条：图标、`description`、`createdAt`、带符号 `points` | `PointsProvider.records` |
| 空态 | 「暂无积���记录」+ 副标题 | — |

**统计口径**（重要）：

- `PointsProvider._loadRecords()` 调 `getPointsRecords(limit: 50)` —— **只取最近 50 条**，SQL 是 `SELECT * FROM points_records ORDER BY created_at DESC LIMIT 50`。
- **没有分页、没有「加载更多」**。数据库里有 500 条流水，用户永远只看到最新 50 条。
- **没有任何汇总统计**（无总收入、无总支出、无按 type 分组）。明细页就是逐条列表。

**每条流量的展示规则**：
- 收支：`points > 0` → 绿色 `+N`；否则红色 `N`（负号直接来自 DB 值）。
- 时间：内嵌版用 `record.createdAt.toString().substring(0, 16)`（Dart `DateTime.toString()` 前 16 字符，形如 `2026-10-20 09:30`）。死代码版用 `DateFormat('MM-dd HH:mm')`。**照搬生效版**。
- 图标：内嵌版只按正负分 `add_circle` / `remove_circle`，**不按 type 区分**。死代码版有 7 种 type 的图标映射表（`points_record_page.dart:127`）——若 RN 侧想做差异化图标，那份映射表可直接复用。

**Provider 刷新时机**：`addPointsWithRecord` / `deductPointsWithRecord` 内部会 `_loadUserPoints()` + `_loadRecords()`；商城兑换走 `reload()`（`points_provider.dart:105`，因为积分被事务直接改了）。

### A.9 死代码 / 未接线清单

| 符号 | 位置 | 状态 |
|---|---|---|
| `PointsPage` | `modules/points/pages/points_page.dart` | **完全未引用**，内容是硬编码假数据 |
| `PointsRecordPage`（模块版） | `modules/points/pages/points_record_page.dart` | **未被引用**，真正生效的是 profile 内嵌版 |
| `PointsRepository` | `modules/points/repositories/points_repository.dart` | 无任何调用方（Provider 直连 `DatabaseService`） |
| `PointsStatisticAdapter` | `modules/points/adapters/points_statistic_adapter.dart` | 无任何调用方 |
| `PointsProvider.updatePoints()` | `points_provider.dart:40` | 无调用方（唯一能覆盖写余额的口子，UI 上不存在） |
| `DatabasePointsMixin.clearPointsRecords()` | `database_points_mixin.dart:166` | 无调用方 |
| `DatabasePointsMixin.addPointsRecord()` | `database_points_mixin.dart:115` | 无调用方（流水一律走事务版） |

> 🔍 **不看代码绝对猜不到**：`PointsProvider.updatePoints()`（覆盖写余额）和 `PointsRepository.setPoints()` **没有任何 UI 入口**。用户**无法**手动改积分。所以 `balance == SUM(points_records.points)` 这个不变量在正常路径下成立。

---

## B. 商城（shop）

### B.1 `shop_items` 字段含义

| 列 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | — | 商品 id，**被 `purchased_items.shop_item_id` 与 `points_records.related_id`（`shop_purchase`）引用** |
| `name` | TEXT NOT NULL | — | 商品名，**无 UNIQUE 约束**，可重名 |
| `description` | TEXT NOT NULL | — | 描述，**NOT NULL**（建商品表单里是必填） |
| `price` | INTEGER NOT NULL | — | 积分数，无小数，**无下限约束**（表单不校验正数） |
| `created_at` | TEXT NOT NULL | — | ISO8601 本地 |
| `icon_name` | TEXT NOT NULL | `'shopping_bag'` | Material 图标名，见 B.1.1 |
| `color_value` | INTEGER NOT NULL | `4278190335` | **ARGB 整数** `0xFF9C27B0` |

> ⚠️ **颜色类型对比（必须记牢）**：
> - `shop_items.color_value` / `purchased_items.color_value` = **ARGB 整数**（如 `4278190335`）
> - `tags.color` = **字符串** `'<#RRGGBB>'`（如 `'#2196F3'`）
> 两者在 RN 侧渲染方式完全不同，不能共用一个解析函数。`schema-v3.md §2.3` 关于 tags 的描述是**正确的**，已核实 DDL（`database_schema_mixin.dart:126`）：`color TEXT NOT NULL DEFAULT '#2196F3'`。

#### B.1.1 `icon_name` 的取值集合

图标是**字符串枚举**，映射表在 Dart 侧硬编码（`shop_model.dart:25`）。表单只能选这 28 个：

```
shopping_bag, card_giftcard, star, favorite, emoji_events, local_cafe,
restaurant, cake, icecream, sports_esports, movie, music_note, book,
sports, fitness_center, flight, beach_access, pets, shopping_cart,
phone_iphone, laptop, headphones, watch, camera, lightbulb, eco,
local_florist, spa
```

**未命中的兜底**：`iconMap[iconName] ?? Icons.shopping_bag` —— 未知图标名静默降级为购物袋，**不报错**。RN 侧需要自建同名字符串 → 图标组件的映射表。

#### B.1.2 默认商品（首次启动自动播种）

`shop_provider.dart:42` `_initDefaultShopItems()`：当 `shop_items` **为空**时插入 8 个商品。

| name | price | icon_name | color_value |
|---|---|---|---|
| 休息15分钟 | 50 | `local_cafe` | `0xFF795548` |
| 看一集动漫 | 100 | `movie` | `0xFFE91E63` |
| 吃一块蛋糕 | 80 | `cake` | `0xFFFF9800` |
| 玩游戏30分钟 | 120 | `sports_esports` | `0xFF9C27B0` |
| 买一本书 | 200 | `book` | `0xFF4CAF50` |
| 周末旅行 | 500 | `flight` | `0xFF2196F3` |
| 买新装备 | 300 | `laptop` | `0xFF607D8B` |
| SPA放松 | 400 | `spa` | `0xFF00BCD4` |

> 🔍 **不看代码绝对猜不到**：判定条件是 **`shop_items` 表为空**，不是「用户没建过商品」。用户**手动删光**所有商品后重启 App，这 8 个商品会**重新长出来**。RN 侧必须复刻这个行为，否则用户删商品后重启会看到商品复活而困惑。
>
> 播种时机：`ShopProvider.initialize()` → `_loadShopItems()` → `_loadPurchasedItems()` → `_initDefaultData()`（顺序固定，先加载后播种，播完再 `_loadShopItems()` 刷新）。

### B.2 `purchased_items` 为什么是快照

DDL（`database_schema_mixin.dart:60`）：`id`、`shop_item_id`、`name`、`description`、`price`、`purchased_at`、`icon_name`、`color_value`。

**存了当时的 5 个展示字段**：`name`、`description`、`price`、`icon_name`、`color_value`。

**原因**：商品改名 / 改价 / 换图标 / 换颜色后，**历史兑换记录不应跟着变**。若只存 `shop_item_id` 并做关联查询，改价会让历史记录的价格一起变，用户会看到「我上次明明花了 50 分，怎么现在显示 200」。

**代价**：`shop_items` 那一行被**物理删除**（`deleteShopItem`）后，`purchased_items.shop_item_id` 变成悬空引用。但因为展示全靠快照列，**UI 完全无感知**。

> ⚠️ `shop_item_id` 是 `NOT NULL` 但**没有外键约束**（DDL 里没声明 `FOREIGN KEY`），所以删除商品不会失败、不会级联、不会留下校验错误。
>
> ⚠️ **`description` 是 `NOT NULL`**：如果历史商品的 description 是空串，`PurchasedItem.fromMap` 正常；但**任何绕过 `ShopItem` 直接构造 `PurchasedItem` 的路径**若传 null 会插入失败。RN 侧写入时 `description ?? ''` 兜底。

`schema-v3.md §5` 第 7 条「`purchased_items` 是快照，不要做关联纠正」——**正确，与代码一致**。

### B.3 兑换流程（完整 SQL，在同一个事务里）

**Provider 层的前置校验**（`shop_provider.dart:137` `purchaseItem`）：

```
1. if (item.id == null) return '商品信息错误'
2. if (_pointsProvider.currentPoints < item.price) return '积分不足，无法兑换'   ← 读内存缓存的余额
3. success = await _repository.purchaseItem(item)   ← 数据库事务
4. if (!success) return '积分不足，无法兑换'
5. await _pointsProvider.reload()                   ← 事务直接改了积分，Provider 缓存已过期
6. await _loadPurchasedItems()
7. await _statisticAdapter.reportExchange(...)      ← 埋点
8. return null                                      ← null = 成功
```

> 🔍 **不看代码绝对猜不到**：步骤 2 用的是 **Provider 内存里的 `currentPoints`**（可能已过期），不是数据库实时值。它只是一层 UX 快速反馈，**真正的余额校验在事务内**（步骤 3）。所以步骤 2 可能误判「余额够」而事务失败（此时返回同一个错误文案），也可能因缓存过期误判「余额不够」而**直接拒绝**——即使数据库里其实有足够积分。RN 侧若要 1:1 复刻这个行为，读缓存；如果想修正（去掉步骤 2），那是**行为变更**，需明确决策。

**数据库事务**（`database_purchase_mixin.dart:19` `purchaseShopItem`）——**这是 RN 侧必须逐行照搬的部分**：

```sql
-- 全部在 BEGIN ... COMMIT 内
-- 步骤 A：确保 user_points 行存在
SELECT id FROM user_points WHERE id = 1 LIMIT 1;
-- 若空：INSERT INTO user_points (id, points, updated_at) VALUES (1, 0, <nowIso>);

-- 步骤 B：原子扣分（余额校验下推到 WHERE）
UPDATE user_points
   SET points = points - ?, updated_at = ?
 WHERE id = 1 AND points >= ?;          -- ? = price
-- 若 affectedRows == 0 → return false → 整个事务回滚，零写入

-- 步骤 C：写积分流水
INSERT INTO points_records (points, type, description, related_id, created_at)
VALUES (-<price>, 'shop_purchase', '购买商品: <item.name>', <shop_item_id>, <nowIso>);

-- 步骤 D：写已购快照
INSERT INTO purchased_items (shop_item_id, name, description, price, purchased_at, icon_name, color_value)
VALUES (<shop_item_id>, <item.name>, <item.description>, <item.price>, <nowIso>,
        <item.icon_name>, <item.color_value>);
```

> ⚠️ **步骤 D 的 `price` 来自 `item.price`，不是步骤 B 用的 `price` 参数**。签名是 `purchaseShopItem({required ShopItem item, required int price})`，两个都传 `item.price`（`shop_repository.dart:34`），所以当前一致。但 RN 侧若允许「用当前商品价以外的价兑换」，扣分和快照会不一致。**建议统一用一个变量。**

> 🔍 **不看代码绝对猜不到**：步骤 C 的 `related_id` 是 `shop_item_id`（商品 id），**不是** `purchased_items.id`。`purchased_items` 的 id 是步骤 D 的 `INSERT` 之后才产生的，写流水时拿不到。这解释了 A.3 表格里那行。

> ⚠️ 三步写入在**同一个 `db.transaction`** 内。RN 侧用 op-sqlite 需要 `db.transaction(async tx => {...})` 或 `BEGIN/COMMIT` 手动包。**任何一步失败必须整体回滚**——这正是「不能扣了分却拿不到商品」的防线。

### B.4 积分不够 / 库存

**积分不够**：由步骤 B 的 `WHERE points >= ?` 拦截，`affectedRows == 0` → 事务回滚 → `purchaseShopItem` 返回 `false` → Provider 返回错误文案 `'积分不足，无法兑换'` → UI 弹 SnackBar。**零写入**，不会出现「流水写了但商品没进仓库」。

> 对比 `overdue_deduct`：**不允许**负余额（因为没传 `requireAtLeast`）。同一套 `applyPointsChange` API，两种语义。

**库存**：**没有库存概念**。DDL 无 `stock` / `quantity` 列，代码里 grep 不到任何库存字段（已核实）。商品**无限次兑换**，想要就重复买。

「已兑换 N」只是个**统计展示**：`ShopProvider.getPurchasedItemCount(shopItemId)`（`shop_provider.dart:177`）——注意实现是 `purchasedItems.where(...).length`，即**每次调用都全表线性扫描**。数据量大时 RN 侧应改成 SQL `GROUP BY`，但**结果必须一致**。

### B.5 兑换记录（仓库页）如何展示

`warehouse_page.dart`：

**分组维度是 `name`（商品名），不是 `shop_item_id`。**（`warehouse_page.dart:28`）

```dart
final groupedItems = <String, List<PurchasedItem>>{};
for (final item in shopProvider.purchasedItems) {
  groupedItems.putIfAbsent(item.name, () => []).add(item);   // 按 name 分组
}
```

> ⚠️ **不看代码绝对猜不到**：分组键是**快照里的 name 字符串**，不是 id。所以：
> - 同一个商品改过名 → **分成两组**（旧名一组、新名一组），即使 `shop_item_id` 相同。
> - 两个不同的 `shop_item_id` 但**重名**（`name` 无 UNIQUE 约束）→ **合并成一组**，图标/颜色/描述取 `items.first`。
> - 组的显示顺序 = `purchasedItems` 首次出现该 name 的顺序 = `purchased_at DESC` 的顺序（因为 `getAllPurchasedItems` 是 `ORDER BY purchased_at DESC`）——即**按最近兑换时间倒序**，不是按数量或字典序。

**每组卡片展示**：
- 堆叠图标（数量 >1 / >2 时叠 2~3 层半透明方块）
- 商品名 + `x<count>` 徽章（颜色取 `items.first.color`）
- 描述（`items.first.description`，最多 2 行）
- `兑换价格: <items.first.price>`
- `最近兑换: <items.first.purchasedAt>` —— ⚠️ **`items.first` 是最近的那条**（列表已按 `purchased_at DESC` 排序），所以「最近兑换」是对的；但「兑换价格」和描述也是取最近那条的快照值，若期间商品改过价，**同一组内会显示不同价格但只展示一个**。

**操作**：
| 操作 | 行为 | SQL |
|---|---|---|
| 查看详情 | 底部抽屉（可拖拽，0.3~0.8 高度），列出该组**全部**条目，每条可单独删除 | — |
| 使用（主按钮） | 删掉 `items.last`（**最旧的那条**） | `DELETE FROM purchased_items WHERE id = ?` |
| 单条删除 | 抽屉里每条右侧垃圾桶图标，同样走「确认使用」对话框 | 同上 |
| 空态 | 「仓库空空如也\n快去积分商城兑换商品吧！」 | — |

> 🔍 **不看代码绝对猜不到**：「使用」按钮删的是 **`items.last`**，也就是**最旧**的一条。而卡片上显示的价格/描述来自 `items.first`（最新的一条）。**删除的记录和显示的记录不是同一条**。这是有意为之（先消耗囤积 oldest-first），但极易看错。

**「使用」不退还积分、不留痕**：只 `DELETE FROM purchased_items`，**不写** `points_records`，**不改** `user_points`。所以「余额 == SUM(流水)」的不变量不受影响。

### B.6 `custom_prize_pool` 是干什么的、谁在写

**它属于刮刮乐模块，不属于商城**。但商城与它**有直接耦合**（下文说明），所以必须在此交代。

| 项 | 说明 |
|---|---|
| 表结构 | `id TEXT PK`（**非自增，字符串 id**）、`name`、`type`、`value`、`weight REAL DEFAULT 1.0`、`is_default INTEGER DEFAULT 0` |
| 用途 | 刮刮乐的**自定义奖品池**。每行一个奖品选项，`weight` 是抽中的权重，`type='none'` 表示「谢谢参与」 |
| 谁在写 | `DatabaseScratchMixin.saveCustomPrizePool(List<PrizeItem>)`（`database_scratch_mixin.dart:52`）。由 `ScratchPrizePoolMixin` 调用 |
| 写入方式 | **全量覆盖**：`DELETE FROM custom_prize_pool;` 然后逐条 `INSERT`。**无事务包裹** |
| 谁在读 | `getCustomPrizePool()` → `SELECT * FROM custom_prize_pool`（**无 ORDER BY**） |

**与商城 / 积分的耦合**（`business-rules.md §4.2`）：

| `prize_type` | 发奖行为 |
|---|---|
| `'none'` 或 `prizeValue <= 0` | 不发任何奖励 |
| **`'goods'`** | **按 `prizeName` 去 `shop_items` 找同名商品** → 找到则写入 `purchased_items`；**找不到则抛错** |
| 其它 | 写 `points_records(points = +prizeValue, type = 'scratch_win')` |

> 🔍 **不看代码绝对猜不到**：刮刮乐抽中「商品」奖品时，**是靠 `shop_items.name` 字符串匹配去兑换的**，而且**免费**——不扣积分、不写 `shop_purchase` 流水，直接 `INSERT INTO purchased_items`。后果：
> - 商品改名后，已配好的奖品池会**匹配不到 → 抛错**。
> - 该奖品会退化成 `scratch_refund`（退还 `cost_points`）。
> - 因此**在商城里删除或改名商品，会静默破坏刮刮乐奖品池**。
>
> 这条耦合**跨越了模块边界**。RN 侧实现刮刮乐（M2+）时必须知道；实现商城时**不要**「帮助」清理重名商品。

### B.7 商城埋点

`ShopStatisticAdapter`（`shop_statistic_adapter.dart`）：

| 时机 | Key | 载荷 |
|---|---|---|
| 商城页 `initState` | `pageViewShopHome` | — |
| 仓库页 `initState` | `pageViewShopWarehouse` | — |
| 兑换成功 | `clickShopExchange` | `{itemId, name, points}` |

> 埋点走 `StatisticService`，写 `SharedPreferences` 键 `statistic_cache`（`business-rules.md §3.1`）。**本地存储，不联网**（无后端）。RN 侧可选择**不实现**——无任何功能依赖它。但若要保持行为一致，需一并迁移 `StatisticService`。

### B.8 商城 UI 交互细节

**添加商品的表单**（`add_shop_item_form_widget.dart`，底部弹窗）：

- 字段：名称（必填）、描述（**必填**，因为 DDL 是 `NOT NULL`）、价格（`int.parse`，**不校验正数**——输入 0 或负数能过，负价格会导致「购买」时反而加积分）。
- 图标：28 个可选，默认 `shopping_bag`。
- 颜色：**19 个 Flutter 预设色**（`Colors.red` / `Colors.pink` / ... / `Colors.blueGrey`），写入时 `colorValue: _selectedColor.toARGB32()`。**注意这是 ARGB 整数，与 tags 的 `#RRGGBB` 字符串不同。**
- **没有编辑入口**：`ShopProvider.updateShopItem()` 和 `DatabaseShopMixin.updateShopItem()` **都存在但无任何 UI 调用方**。用户在 App 里**只能新增和删除商品，不能改**。

**商品卡片的可点性**（`shop_page.dart:189`）：`onTap: canAfford ? ... : null` —— **积分不够时整张卡片不可点**，按钮也 `onPressed: null` 并显示灰色「积分不足」。文案「购买」变「积分不足」。

**确认弹窗**：卡片按钮 → 底部详情弹窗 → 「立即兑换」→ `AlertDialog`「确认购买：确定花费 N 积分购买「X」吗？」→ 确认 → `purchaseItem`。

---

## C. 标签（tag）

### C.1 `tags` 与 `task_tags` 的关系

```sql
CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,                      -- ★ 唯一约束（区分大小写，SQLite 默认 BINARY 排序）
  color TEXT NOT NULL DEFAULT '#2196F3',          -- ★ 字符串，不是 ARGB
  icon TEXT,                                       -- 可空
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_tags (
  task_id INTEGER NOT NULL,
  tag_id  INTEGER NOT NULL,
  PRIMARY KEY (task_id, tag_id),                   -- ★ 复合主键 → 天然去重
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id)  REFERENCES tags(id)  ON DELETE CASCADE
);
```

**多对多**：`tags` ←→ `tasks`，通过 `task_tags`。

**一次任务的标签是否唯一**：**是**。`PRIMARY KEY (task_id, tag_id)` 保证同一 (任务, 标签) 组合只有一行。写入时用 `ConflictAlgorithm.ignore` 兜底（`database_tag_mixin.dart:40`）：

```sql
INSERT OR IGNORE INTO task_tags (task_id, tag_id) VALUES (?, ?);
```

→ 重复插入**静默忽略**，不报错。**「一次任务的标签唯一」这个不变量由数据库保证。**

### C.2 `tags.color` 是字符串 —— 已核实

**✅ 确认**。DDL（`database_schema_mixin.dart:126`）：`color TEXT NOT NULL DEFAULT '#2196F3'`。模型 `Tag.color` 是 `String`（`tag_model.dart:8`），默认 `'#2196F3'`。与 `shop_items.color_value`（ARGB 整数）**类型不同**，已在 B.1 标注。

**颜色解析有兜底**（`tag_model.dart:67`）：

```dart
Color get flutterColor {
  try {
    final hex = color.replaceFirst('#', '');
    return Color(int.parse('FF$hex', radix: 16));   // 强制补 FF alpha
  } catch (_) {
    return Colors.blue;                              // 解析失败 → 蓝色
  }
}
```

> 🔍 **不看代码绝对猜不到**：解析时**强制在前面拼 `FF`** 作为 alpha。所以库里存的**永远是 6 位 `#RRGGBB`，不带 alpha**。若某行存了 8 位（`#AARRGGBB`），拼出来会变成 10 位 → `int.parse` 抛异常 → **静默降级为蓝色**（不报错，用户只看到标签变蓝）。
>
> RN 侧：`parseInt('FF' + hex.slice(1), 16)`，失败返回蓝色。**必须 try/catch**，不能抛给用户。

**可选色板（16 色，硬编码）**（`tag_management_page.dart:182`）：

```
#F44336 #E91E63 #9C27B0 #673AB7 #3F51B5 #2196F3 #00BCD4 #009688
#4CAF50 #8BC34A #CDDC39 #FFC107 #FF9800 #FF5722 #795548 #9E9E9E
```

选中态：白色 3px 描边 + 同色半透明光晕 + 白色对勾。

**默认色**：`#2196F3`（添加对话框的初始选中色）。

### C.3 标签的增删改查

**初始化与默认标签**（`tag_provider.dart:18`）：

```
initialize():
  _loadTags()
  if (tags.isEmpty) _createDefaultTags()      -- ★ 与商城同款「表空则重播种」逻辑
```

`Tag.defaultTags`（`tag_model.dart:76`）—— 4 个**系统标签**：

| name | color | icon | is_system |
|---|---|---|---|
| 单词 | `#FF9800` | `translate` | 1 |
| 工作 | `#2196F3` | `work` | 1 |
| 学习 | `#4CAF50` | `school` | 1 |
| 生活 | `#9C27B0` | `home` | 1 |

> 🔍 **不看代码绝对猜不到**：
> 1. **`icon` 列写了 Material 图标名字符串**（`translate` / `work` / `school` / `home`），但**代码里从来没有读取 `tag.icon` 来渲染图标**。UI 上所有标签都用同一个 `Icons.label`（`tag_management_page.dart:109`）。所以 `icon` 列是**纯死数据**。RN 侧可以照存不渲染。
> 2. 和商城一样：**用户删光所有标签后重启，4 个系统标签会重新长出来**。
> 3. 系统标签的 `is_system = 1`，`TagProvider.deleteTag` 里有 `if (tag.isSystem) return;` 拦截（第 52 行）。但 **UI 上系统标签根本不显示删除按钮**（`tag_management_page.dart:119`：`trailing: isSystem ? null : PopupMenuButton`）。这是**双层保护**。

**新增**（UI → Provider → DB）：

```
UI: 名称 trim → 空则报「标签名称不能为空」
    → getTagByName(name) != null 则报「标签已存在」
    → addTag(Tag(name: name, color: selectedColor))
      is_system 默认 false，icon 默认 null，created_at = now
DB: INSERT INTO tags (name, color, icon, is_system, created_at) VALUES (?, ?, NULL, 0, ?)
```

> ⚠️ **重名检查有两套，且语义不同**：
> - **UI 层** `getTagByName` 用 `toLowerCase() == toLowerCase()`（`tag_provider.dart:88`）→ **大小写不敏感**。
> - **数据库层** `name TEXT NOT NULL UNIQUE` 用 SQLite 默认 **BINARY  collation → 大小写敏感**。
>
> 后果：DB 允许同时存在 `Work` 和 `work`，但 UI 的 `getTagByName('WORK')` 会命中先找到的那个并**拒绝创建**。用户会看到「标签已存在」但列表里找不到他想要的那个。RN 侧照搬两层逻辑即可，但**必须知道这是个不一致**。
>
> 另外 UI 层的重名检查**只在新增时做，编辑时不检查**（`_showEditTagDialog` 直接 `updateTag`）。编辑标签名可以撞上另一个标签的名字 → **DB 的 UNIQUE 约束会抛异常**（`UNIQUE constraint failed: tags.name`），而 `updateTag` **没有 try/catch** → 异常向上冒泡。RN 侧应加错误处理并提示用户。

**编辑**：只能改 `name` 和 `color`（`tag.copyWith(name:, color:)`）。`is_system` / `icon` / `created_at` 不可改（UI 不提供）。系统标签**无编辑入口**。

**删除**（`tag_provider.dart:50`）：

```dart
Future<void> deleteTag(int tagId) async {
  final tag = _tags.firstWhere((t) => t.id == tagId);   // 找不到会抛 StateError
  if (tag.isSystem) return;                              // 系统标签保护
  await _db.deleteTag(tagId);                            -- DELETE FROM tags WHERE id = ?
  await _db.deleteTaskTagsByTagId(tagId);                 -- DELETE FROM task_tags WHERE tag_id = ?
  await _loadTags();
}
```

> ✅ **回答「级联没生效，代码里有没有手动清理」：有，但只清理了一半。**
> - **删标签** → **有**手动清理 `task_tags`（`deleteTaskTagsByTagId`）。所以删标签**不会**产生 `task_tags` 孤儿行。
> - **删任务** → **不立即清理**。`task_repository.dart:188` 的 `txn.delete('tasks', where: 'id = ?')` 之后**没有任何 `task_tags` 清理**。`grep task_tags lib/modules/tasks/ lib/providers/` → **零命中**。
>   ⚠️ **但这不是终点**：该任务被**永久删除**时（回收站裁剪 / 清空 / 单条永久删除 / 批量 `deleteAll:true` 物理删除）
>   必须**同事务**清掉它的 `task_tags` 行——见 **V1**。不立即清是为了恢复时标签能自动接回（V4）。
>
> 🔍 **V3 关键措辞：删任务时「不立即清理」，而非「不清理」。**
> Flutter 现状是「移入回收站时不清理关联行」；V1 补充要求**在宿主确定消失的那一刻（同事务）清理**。所以孤儿行仍会产生，但**生命周期有终点**，不会永久累积。详见 X3。
>
> 🔍 **谁在什么时候清理**（V3 要求写明，避免歧义）：
>
> | 时刻 | 是否清理 | 覆盖的删除路径 |
> |---|---|---|
> | 移入回收站（`deleteTask` else 分支） | ❌ **不清理** | 单次删除非循环任务 |
> | 回收站裁剪（`_cleanupRecycledTasksTxn`） | ✅ **同事务清理** | 上限 10 条溢出 |
> | 清空回收站（`clearRecycleBin`） | ✅ **同事务清理** | 全部条目 |
> | 回收站内单条永久删除（`deleteFromRecycle`，`:380`） | ✅ **同事务清理** | V1 补充 |
> | **批量删循环任务**（`deleteAll: true`，`:148`） | ✅ **同事务清理**，且**须新引入事务** | V1 补充 |
> | 手动兜底 `purgeOrphanTaskTags()` | 仅历史脏数据，**不自动调用** | M2 设置页手动入口 |
>
> 🔍 **「同事务清理」在 `deleteAll` 分支需额外引入事务**：该分支（`:148-163`）是逐条 `await db.delete(...)`，**不在事务内**（对比 else 分支 `:164` 才有 `_gateway.transaction`）。M1 要把它包进事务——理由是**原子性修复**，不是产品行为变更；且既然要在同一处加清理，不包事务无法保证一致性。
>
> `schema-v3.md §5` 第 4 条「`task_tags` 很可能有孤儿行」——**完全正确**，根因已定位。

**查询**：

| API | SQL |
|---|---|
| 全部标签 | `SELECT * FROM tags ORDER BY name ASC` |
| 按 id | `SELECT * FROM tags WHERE id = ?` |
| 某任务的标签 | `SELECT t.* FROM tags t INNER JOIN task_tags tt ON t.id = tt.tag_id WHERE tt.task_id = ? ORDER BY t.name ASC` |
| 某标签的任务 id | `SELECT task_id FROM task_tags WHERE tag_id = ?`（**无 ORDER BY**，且 JOIN `tasks` 表确认存在性的活没人干——可能返回已删任务的 id） |

### C.4 任务与标签的关联操作

| API | 行为 | SQL |
|---|---|---|
| `assignTagToTask(taskId, tagId)` | 关联单个 | `INSERT OR IGNORE INTO task_tags (task_id, tag_id) VALUES (?, ?)` |
| `removeTagFromTask(taskId, tagId)` | 解除单个 | `DELETE FROM task_tags WHERE task_id = ? AND tag_id = ?` |
| `setTagsForTask(taskId, tagIds)` | **全量覆盖** | 先 `DELETE FROM task_tags WHERE task_id = ?`，再对每个 tagId `INSERT OR IGNORE` |

**`setTagsForTask` 是主要的写入路径**，两个调用方：
1. `lib/modules/tasks/widgets/task_form_submit_mixin.dart` —— 任务创建/编辑表单提交（新建和编辑**都**调它，所以编辑时清空所有标签再重插）
2. `lib/providers/mixins/task_batch_mixin.dart` `batchUpdateTags` —— 批量改标签

> ⚠️ **`setTagsForTask` 不在事务里**。`DELETE` 成功但 `INSERT` 中途失败（虽然 `INSERT OR IGNORE` 很难失败）→ 任务标签全丢。风险低，但 RN 侧建议包事务。
>
> ⚠️ **`setTagsForTask` 不校验 tagId 是否存在**。传一个已删除的 tagId 会插入孤儿行（`task_tags` 指向不存在的 `tags.id`）。UI 层通过只从现有标签列表选来规避。

**循环任务不复制标签**：`business-rules.md §2.4` 明确「插入只写 `tasks` 表，不写 `task_tags`」。已核实：`generateRecurringTasks` 在 tasks 模块内，本文不展开。**但要注意**——这意味着循环生成的实例**没有任何标签**，即使模板任务有标签。这是**已知行为，不是 bug**（business-rules §6 待核实第 4 条建议「决定是否当作 bug 修」，M1 阶段建议照搬）。

**任务删除时的标签处理**：见 C.3 末尾 —— **不立即清理**（为了恢复时标签能自动接回，H1/H2）；
但在该任务被**永久删除**时同事务清理（V1）。⇒ 孤儿生命周期为 0，不是永久。

---

## D. 回收站（recycled_tasks）

### D.1 哪些操作进回收站 / 哪些永久删除

| 操作 | 入口 | 行为 |
|---|---|---|
| **单条删除任务** | 任务列表/详情的删除、`batchDeleteTasks`（批量） | **进回收站**（`task_repository.dart:166`） |
| **批量删除循环任务** | `deleteTask(id, deleteAll: true)` 且 `recurrence != 'none'` 且 `loopId != null` | **永久删除**，不进回收站 |
| 回收站里单条彻底删除 | 回收站卡片右侧 🗑 | 永久删除该回收站行 |
| 清空回收站 | 回收站 AppBar 🧹 | 永久删除全部回收站行 |
| 裁剪 | 每次进回收站时自动 | 超出 10 条的**最旧**的被物理删除 |
| **删除标签** | 标签管理 | **不进回收站**（标签没有回收站，直接 `DELETE FROM tags`） |
| **使用商品** | 仓库页 | **不进回收站**（直接 `DELETE FROM purchased_items`） |

**批量删循环任务的细节**（`task_repository.dart:148`，永久删除分支）：

```
if (deleteAll && task.recurrence != 'none' && task.loopId != null) {
  tasksToDelete = getTasksByLoopId(task.loopId)          -- 该系列全部实例
  filtered = tasksToDelete.where((t) => !isDateBefore(t.cplTime, task.cplTime))
                                                              -- 只保留 >= 被删任务 cplTime 的
  if (filtered.isEmpty) return;                          -- 全是过去的 → 什么都不删
  earliestTask = filtered.reduce((a,b) => a.cplTime.isBefore(b.cplTime) ? a : b);
  delete tasks where id = earliestTask.id                -- 先删最早的那条
  for (t in filtered where t.id != earliestTask.id) delete -- 再删其余
  -- ★ 注意：循环任务的【过去实例】保留（它们在任务列表的历史日期里可见）
  -- ★ 不立即清理 task_tags（每个被删 id 留一行悬空关联，靠它恢复标签；永久删除时才清理，见 V1）
}
```

> 🔍 **不看代码绝对猜不到**：批量删循环任务时，**只删「被删任务当天及以后」的实例，过去的历史实例保留**。且这个分支**不走事务**（多条独立 `db.delete`），中途失败会删一半。

### D.2 `recycled_tasks` 与 `tasks` 的字段差异

DDL（`database_schema_mixin.dart:80`）：**与 `tasks` 完全相同的 13 列**（`id`、`loop_id`、`title`、`description`、`is_word`、`is_ok`、`cpl_time`、`recurrence`、`completed_at`、`reward_points`、`is_deducted`、`created_at`、`priority`），**额外两列**：

| 列 | 说明 |
|---|---|
| `task_id` | 原任务 id，**仅参考，不保证还能对上** |
| `deleted_at` | 删除时间，ISO8601 本地 |

> ⚠️ **`recycled_tasks.id` 与 `tasks.id` 是两个独立 AUTOINCREMENT 序列**。回收站行的 `id` 是**新分配**的，不是原任务 id。所以 UI 上「恢复/永久删除」用的是 `recycled_tasks.id`，而 `task_id` 只是留档。

**`loop_id` 怎么处理** —— 这是本模块**代码与文档不一致**的核心点：

| 实现 | 是否写 `loop_id` | 是否是实际生效的 |
|---|---|---|
| `TaskRepository.deleteTask`（`task_repository.dart:171`） | ✅ **写入** `'loop_id': taskMap['loop_id']` | ✅ **是**。所有删除都走这里 |
| `DatabaseTaskMixin.moveTaskToRecycleBin`（`database_task_mixin.dart:215`） | ❌ **不写**（insert map 里没有 `loop_id`） | ❌ **死代码**，`grep moveTaskToRecycleBin lib/ android/` 只命中定义处，**零调用方** |

`TaskRepository.restoreTaskFromRecycle`（`task_repository.dart:350`）**读取** `recycledMap['loop_id']`，并传给 `Task(loopId: ...)`。`DatabaseTaskMixin` 里的同名方法（`:276`）**不读** `loop_id`。

> ✅ **结论：以 `TaskRepository` 为准**（`loop_id` 写入且读回，循环链不断）。`DatabaseTaskMixin` 的两个方法是历史遗留死代码，**RN 侧不要参考**。
> `schema-v3.md §2.2` 的描述「v3 才补的 `loop_id`：没有它，循环任务从回收站恢复后不再生成后续实例」——**正确**，且描述的正是 `TaskRepository` 这条生效路径。

### D.3 移入回收站的完整 SQL

`task_repository.dart:166`，**单个事务**：

```sql
BEGIN;
-- 先读出完整行
SELECT * FROM tasks WHERE id = ? LIMIT 1;
-- 若空 → 直接 return，什么都不做

-- 插入回收站（loop_id 必须带上！）
INSERT INTO recycled_tasks
  (task_id, loop_id, title, description, is_word, is_ok, cpl_time,
   recurrence, completed_at, reward_points, is_deducted, created_at,
   priority, deleted_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, <nowIso>);

-- ★ 插入成功后立刻裁剪
SELECT id, task_id FROM recycled_tasks ORDER BY deleted_at DESC;
-- 若总数 > 10：把第 11 条及以后的（最旧的）逐条处理
--   ① 先 DELETE FROM task_tags WHERE task_id = ?;   ← 用 task_id，不是 recycled_tasks.id！
--   ② 再 DELETE FROM recycled_tasks WHERE id = ?;
-- ⚠️ 被裁剪的条目其任务已永久删除 → 标签关联无处可挂，必须同事务清掉（V1）
-- ⚠️ 顺序不可换：子查询依赖 recycled_tasks 那行还在

-- ★ 只有插入成功才删原任务
DELETE FROM tasks WHERE id = ?;
COMMIT;
```

> ⚠️ **`deleted_at` 排序的稳定性问题**：裁剪用 `ORDER BY deleted_at DESC` + `skip(10)`。如果同一毫秒内删了多条任务，`deleted_at` 相同（ISO8601 带微秒，冲突概率极低），裁剪顺序不确定。RN 侧建议 `ORDER BY deleted_at DESC, id DESC` 更稳，**但这会改变极端情况下的行为**。建议照搬 `ORDER BY deleted_at DESC` 以保证一致。

**回收站保留策略**：

| 项 | 值 |
|---|---|
| 条数上限 | **10 条**（`task_repository.dart:200`） |
| 时间过期 | **无**。不按天、不按小时清理 |
| 触发时机 | **每次移入新任务时**裁剪（逐条、每次一个独立事务）。App 长期不删任务，回收站就一直是那 ≤10 条 |
| 裁剪对象 | `deleted_at DESC` 排序后的第 11 条起（**最旧的**） |

> 🔍 **G2 复述**：这就是「不看代码绝对猜不到」的第 2 条。用户问「删除的任务会保留多久」，UI 文案写「删除的任务会在这里保留一段时间」（`recycle_bin_page.dart:58`）—— **这是误导性的**，真实规则是「只留最近 10 条」。删了 11 个任务，第 1 个**立即**被物理删除，不可恢复。

> ⚠️⚠️ **批量删除会「即时丢任务」，这是上限 10 条最反直觉的表现。**
>
> `task_batch_mixin.dart:52` 的 `batchDeleteTasks()` 是**逐条同步**调用 `deleteTask(taskId)`（不传 `deleteAll`，所以走回收站路径）：
> ```dart
> Future<String?> batchDeleteTasks() => _runBatch('删除', (taskId) async {
>   await deleteTask(taskId);      // 每条一个独立事务：插入 → 裁剪 → 删原任务
>   return true;
> });
> ```
>
> **后果**：批量删 15 个任务 → 循环 15 次「插入 + 裁剪到 10」→ **前 5 个刚插进回收站就被物理删除**。用户在批量删除后只会看到 10 条，**且没有任何提示**。
>
> **RN 侧必须确认**：裁剪是逐条同步跑（照搬 → 用户会丢任务），还是先收集后统一裁剪（行为不同 → 与 Flutter 不一致）。**建议照搬以保持一致**，但若要改善，这是最值得动的一处。

> RN 侧的 UI 文案建议**如实告知「仅保留最近 10 条」**——这是修正文案，不改行为。

### D.4 恢复操作：id 会变，AUTOINCREMENT 没问题

> ⚠️ **本节整体描述的是 Flutter 现状**（恢复走自增新 id）。
> **RN 侧不照搬**：按 `m1-decisions.md` **H1**，恢复时**写回原 `task_id`**，不走自增、不丢 `task_id`。
> 下面所有「id 悬空 / 引用失效」的推论**都不适用于 RN**，但**保留**在此——
> 它们记录了「若不修会怎样」，是 H1 决策的依据。

`task_repository.dart:337` `restoreTaskFromRecycle`：

```sql
BEGIN;
SELECT * FROM recycled_tasks WHERE id = ?;
-- 若空 → throw Exception('回收站任务不存在')

-- 用回收站的字段构造一个新 Task（loop_id 带上）
INSERT INTO tasks (loop_id, title, description, is_word, is_ok, cpl_time,
                   recurrence, completed_at, reward_points, is_deducted,
                   created_at, priority)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
-- ★ 注意：没有插入 id 列 → SQLite 自动分配新的 AUTOINCREMENT id

DELETE FROM recycled_tasks WHERE id = ?;
COMMIT;
```

#### 回答「会不会与新建的任务 id 冲突 / AUTOINCREMENT 会不会出问题」

**不会冲突，AUTOINCREMENT 工作正常。** 逐条分析：

| 问题 | 答案 | 理由 |
|---|---|---|
| 会用回原来的 id 吗？ | **不会** | `INSERT` 不含 `id` 列，SQLite 从 `sqlite_sequence` 分配**全新** id |
| 会撞上已存在的 id 吗？ | **不会** | `tasks.id` 是 `INTEGER PRIMARY KEY AUTOINCREMENT`，带单调递增序列，且 `AUTOINCREMENT` 关键字保证**不复用**已删除的 id |
| `sqlite_sequence` 会错乱吗？ | **不会** | 恢复是「插入新行」，序列自然 +1。原任务被删时 id 已从表里消失但序列不回退——这正是 `AUTOINCREMENT` 的设计目的 |
| 需要手动搬 `sqlite_sequence` 吗？ | **不需要** | 迁移旧库时才需要（`schema-v3.md §5` 第 1 条），运行时不需要 |

**但恢复有三个「不看代码绝对猜不到」的后果**：

#### ① 任务的 id 变了 → **四个**引用失效

| # | 表.列 | 原来指向 | 恢复后 | 后果 |
|---|---|---|---|---|
| 1 | `task_tags.task_id` | 原 id | ❌ 孤儿 | 标签关联丢失 |
| 2 | `points_records.related_id`（`task_complete` / `task_uncomplete`） | 原 id | ❌ 悬空 | 结算状态查不到 → **重复加分** |
| 3 | `points_records.related_id`（`overdue_deduct`） | 原 id | ❌ 悬空 | 逾期记录查不到 → **重复扣分**（更隐蔽，见下） |
| 4 | `pomodoro_records.related_task_id` | 原 id | ❌ 悬空 | 番茄钟历史关联不上该任务 |

> 🔍 **1 与 2：重复加分（详见下方场景）**
>
> **场景**：任务 A（id=5）完成 → 加 10 分，写 `points_records(related_id=5, type='task_complete')`。删掉 A → 进回收站。恢复 A → 得到 id=12。
> `getLatestPointsRecord(12, ['task_complete','task_uncomplete'])` → **查不到**（记录在 related_id=5）→ `latest == null` → **再加 10 分**。
> `balance == SUM(流水)` 仍成立（两笔都记了），但**用户只完成一次却拿两份积分**。
>
> 🔍 **3 比 2 更隐蔽**：逾期扣分走的是**另一个查询** `hasPointsRecordByTypeAndRelatedId('overdue_deduct', taskId)`（`task_settlement_mixin.dart:13`），不是 `getLatestPointsRecord`。
> ⚠️ **【作废】** 这条推论已被 `m1-decisions.md` **T1** 推翻：逾期扣分有**两道门**
> （`is_deducted = 0` 与 `points_records` 按 id 查流水），是「与」不是「或」；
> 而**编辑与恢复都不会重置 `is_deducted`**，所以第一道门始终关着 → **Flutter 现状不存在重复扣款**。
> 原文（保留作纠错记录）：任务恢复后若再次逾期 → 新 id 查不到旧 `overdue_deduct` → **再扣一次分**。
> 改写为 **🔴 RN 实现红线**：实现 H1 时**绝不能顺手把 `is_deducted` 置 0**，
> 否则两道门同时失效 → 真扣钱且余额无下限保护。
>
> 🔍 **4**：番茄钟记录的 `related_task_id`（`database_pomodoro_mixin.dart:52` 有 `WHERE related_task_id = ?` 查询）。`related_task_title` 是快照所以标题不丢，只是按任务查历史时关联不上。

> ✅ **裁决：M1 照搬（接受上述全部四个缺陷）**，见 X1。
> 若将来要修，`related_id` 的修正 **WHERE 条件必须覆盖全部三个 task 相关 type**：
> ```sql
> UPDATE points_records SET related_id = :newId
>  WHERE related_id = :oldId
>    AND type IN ('task_complete', 'task_uncomplete', 'overdue_deduct');  -- ← 漏掉 overdue_deduct 会导致重复扣分
> ```
> **且必须与积分幂等判定同一个 PR 一起改**——复用 id 会让旧流水重新认领任务，方向与现状相反（X1）。

#### ② 标签关联永久丢失

`task_tags` 里 `task_id = 原id` 的行暂时「悬空」。**H1 修复后（恢复时写回原 id）标签会自动接回**——
因为这些行从未被删过，id 一旦重新出现在 `tasks` 里，关联即恢复。
两个前提（H1 成立 + 该条目仍在回收站内）见 V4；被裁剪/清空意味着任务已永久删除，关联随之失效。

> 若要支持恢复标签，必须**在 `recycled_tasks` 加一列**存标签快照（如 `tag_ids TEXT` 逗号分隔）。这是 **schema 变更**（`dbVersion` 要 +1），超出 M1 范围。**标注为已知限制。**

#### ③ `task_id` 列是「唯一能找回原 id 的线索」

因为 `related_id` 和 `task_tags` 都指向原 id，`recycled_tasks.task_id` 是修复上述问题的**唯一依据**。方案 B 依赖它，所以**这一列必须严格保留**。

**恢复后 Provider 侧的额外动作**（`task_recycle_mixin.dart:5`）：

```
1. 记下 originalCplTime = recycledTask.task.cplTime
2. restoredTask = restoreTaskFromRecycle(id)
3. _invalidateMonthCache(originalCplTime)               -- 清月视图缓存
4. if (restoredTask.recurrence != 'none')               -- ★ 循环任务额外一步
     generateRecurringTasks(restoredTask.copyWith(cplTime: originalCplTime))
5. _loadRecycledTasks()
6. loadTasksByDate(_selectedDate)
```

> 🔍 **不看代码绝对猜不到**：恢复循环任务时**用 `originalCplTime`（回收站里存的原始日期）重新触发生成**，而不是用恢复后的日期。这会让**生成器从旧的 `cplTime` 开始回补到今天**（`business-rules.md §2.2`：无下界，从模板 `cplTime` 当天逐日生成，上界 `now + 15 天`）。
>
> 后果：删掉一个 3 个月前的每日循环任务再恢复 → **一次性生成约 90+ 个新任务实例**。用户会看到任务列表「凭空爆炸」。
>
> 这是 tasks 模块的行为，**本文只标注依赖点**。但**回收站恢复循环任务是触发它的主要入口之一**，实现回收站时必须知道。

### D.5 「仅恢复当天」——恢复对话框的第二个选项

`recycle_bin_page.dart:230` —— 恢复**循环任务**时弹三个按钮：

| 按钮 | 行为 |
|---|---|
| 取消 | 关闭 |
| **仅恢复当天** | `deleteFromRecycle(id)`（先删回收站行）→ `addTask(task.copyWith(recurrence: 'none'))`（**新建**一个 `recurrence='none'` 的任务） |
| 恢复循环 | `restoreTaskFromRecycle(id)`（走 D.4 的搬回流程） |

> 🔍 **「仅恢复当天」不走 `restoreTaskFromRecycle`**，而是「删掉回收站行 + 全新插入」。后果：
> - `loopId` **保留**（`copyWith` 不动它）——但 `recurrence='none'` 时 `loopId` 不参与任何逻辑，无害。
> - **原 id 一样丢失**（新 id）。
> - 标签一样丢失。
> - **不会**触发循环回补（D.4 的第 4 步不执行）。
> - `created_at` 保留原值（`RecycledTask.task.createdAt`），但 `cplTime` **保留原日期**——**不是「当天」**！按钮叫「仅恢复当天」，实际是「只恢复这一个实例、不恢复循环」。
>
> ⚠️ **按钮文案与行为不符**：「仅恢复当天」听起来像「恢复到今天」，实际是「仅恢复此实例（保持原日期）但关闭循环」。RN 侧要么照搬文案（保持一致），要么改文案（行为不变）。**建议改文案为「仅恢复此实例」并在文档记录。**

非循环任务（`recurrence == 'none'`）的恢复对话框只有「取消 / 恢复」两个按钮，直接走 `restoreTaskFromRecycle`。

### D.6 回收站列表展示什么

| 区域 | 内容 |
|---|---|
| AppBar | 标题「任务回收站」；**有数据时**显示 🧹 图标（清空） |
| 卡片标题 | `task.title` |
| 卡片描述 | `task.description`（非空才显示） |
| 标签行 | ① `单词任务`（橙）/ `普通任务`（蓝）② 重复：`每天`/`每周`/`每月`/`一次性`（绿）③ `+N积分`（琥珀，**仅 `rewardPoints > 0` 时**） |
| 时间 | `删除时间：YYYY-MM-DD HH:mm`（**手工格式化，不带秒**） |
| 操作 | 🔄 恢复（有确认对话框）｜🗑 永久删除（**无确认**，直接删） |
| 空态 | 「回收站是空的」+「删除的任务会在这里保留一段时间」（**文案不准确，见 D.3**） |
| 排序 | `deleted_at DESC`（最近删除的在前） |

> ⚠️ **永久删除没有二次确认**（`recycle_bin_page.dart:129`：`onPressed: () => taskProvider.deleteFromRecycle(recycledTask.id)`，直接调）。而「清空回收站」**有**确认对话框。这是**不一致的交互**，容易误触。RN 侧照搬 or 加确认 —— 建议加（属交互改进，不改数据行为）。
>
> ⚠️ **卡片不展示 `priority`**（`tasks` 表有这个字段，回收站卡片没渲染）。也不展示完成状态 `is_ok`。

### D.7 清空 / 批量操作

| 操作 | API | SQL |
|---|---|---|
| 清空全部 | `clearRecycleBin()` | `DELETE FROM recycled_tasks`（**无 WHERE，全表删，无事务**） |
| 单条永久删除 | `deleteFromRecycle(recycledTaskId)` | `DELETE FROM recycled_tasks WHERE id = ?` |
| 批量删除 | **不存在** | 只能「清空全部」 |

**清空不触发任何连带清理**：
- ❌ 不删 `task_tags`（本来就没有有效的）
- ❌ 不动 `points_records`（**已获得的积分不退还**——这是对的，否则能靠删任务刷分）
- ❌ 不动 `user_points`

> ✅ **积分与回收站完全解耦**：删除任务**不退还**已获得的积分，永久删除回收站行也**不退还**。所以「删任务 → 恢复 → 再完成」在积分上是可利用的（见 D.4① 的重复加分），但「删任务 → 清空回收站」不会额外改变余额。

### D.8 回收站没有独立模块 —— 依赖清单

回收站**没有 `lib/modules/recycle/`**。逻辑分布：

| 层 | 文件 | 内容 |
|---|---|---|
| UI | `lib/modules/tasks/pages/recycle_bin_page.dart`（303 行） | 回收站页面 |
| 入口 | `lib/modules/profile/pages/data_management_page.dart:149` | 「我的 → 数据管理 → 任务回收站」 |
| 路由 | `lib/core/router/app_router.dart:28,56` | 常量 `recycleBin = '/recycle-bin'` + `RecycleBinPage` 分支。⚠️ **实际代码用的是 `MaterialPageRoute` 直接 push，`AppRouter.recycleBin` 常量与分支从未被调用**（同 `PointsPage`  situation） |
| Provider | `lib/providers/mixins/task_recycle_mixin.dart`（33 行） | `restoreTaskFromRecycle` / `deleteFromRecycle` / `clearRecycleBin`，每个都后接 `_loadRecycledTasks()` |
| 状态 | `lib/providers/mixins/task_provider_core_mixin.dart:15,36,99` | `_recycledTasks` 列表 + getter + `_loadRecycledTasks()` |
| 启动加载 | `lib/providers/task_provider.dart` `initialize()` | `_loadRecycledTasks()` |
| Repository | `lib/modules/tasks/repositories/task_repository.dart` | **真正的 SQL 在这里** |
| 模型 | `lib/modules/tasks/models/task_model.dart` | `RecycledTask` 类（`{id, task, deletedAt}`，`task` 是完整的 `Task` 对象） |
| 死代码 | `lib/core/services/database/database_task_mixin.dart:205,238,244,263,305,314` | **仅「回收站写入侧」6 个方法无外部调用方**。`:244`（`_cleanupRecycledTasksTxn`）仅被同为死代码的 `:232` 调用，属传递性死亡 |

> ⚠️⚠️ **读取侧不是死代码：`getRecycledTasks`（`:257`）与 `getAllTasks`（`:37`）都活着。**
> - `getRecycledTasks` ← `data_export_page.dart:300`（数据导出页「导出回收站」开关）
> - `getAllTasks` ← `data_export_page.dart:278`（数据导出页「导出任务」开关）
>
> **若 RN 侧把它们当死代码不实现 → 数据导出功能整块缺失。** 详见 §E.5。
>
> ℹ️ **两个 `getRecycledTasks` 实现行为一致**：`spec-review.md`（QA，任务 #14）称「mixin 版返回 5 字段、Repository 版返回 10 字段」，**实测不成立**——mixin 版（`:257`）与 Repository 版（`:396`）的 SQL 字符级相同，都是 `SELECT * FROM recycled_tasks ORDER BY deleted_at DESC`，都走 `RecycledTask.fromMap` → 15 字段。**唯一差异是数据库句柄来源**（`await database` vs `await _db`）。**实现任一版都可以**，不存在「字段不一致」的风险。
>
> ⚠️ 但 review 的**结论**（两个都活、都别当死代码删）是对的，只是**理由**不成立。若照「字段数不同」做防御性字段映射，反而是引入多余复杂度。

> ⚠️ **给 RN 实现者的警告**：`DatabaseTaskMixin` 与 `TaskRepository` 存在**同名方法的双份实现**，且行为不一致（最关键的就是 `loop_id`）。测试文件 `test/core/database_task_mixin_test.dart:254` 有明确注释承认这一点：
> ```dart
> // 已知行为：DatabaseTaskMixin.moveTaskToRecycleBin / restoreTaskFromRecycle
> // 不搬运 loop_id，循环链需由 TaskRepository 层补偿修复。
> expect(restored.loopId, isNull);
> ```
> 测试在**断言这个缺陷存在**，而不是在测正确行为。**实现回收站时只参考 `TaskRepository`，照着 mixin 写会丢掉循环链。** 但 `getRecycledTasks` / `getAllTasks` 是例外，见上。

---

## E. 界面行为清单

### E.1 积分

| 页面/入口 | 路由 | 可执行操作 | 数据变化 |
|---|---|---|---|
| **我的 → 我的积分** | `MaterialPageRoute` push `PointsRecordPage`（profile 内嵌版） | 查看余额 | 只读 |
| ↳ 积分卡片 | — | — | 只读 `user_points.points` |
| ↳ 流水列表 | — | 滚动查看（**上限 50 条，无分页**） | 只读 `points_records` |
| **（死代码）`PointsPage`** | **无路由** | — | **忽略** |

积分的**写入**入口全在任务模块（完成/取消/逾期）+ 商城 + 刮刮乐，**没有独立的积分操作页面**。用户无法手动增减积分。

### E.2 商城

| 页面/入口 | 路由 | 可执行操作 | 数据变化 |
|---|---|---|---|
| **我的 → 积分商城** | `/shop` | — | `initState` 埋点 |
| ↳ 积分横幅 | — | — | 只读 |
| ↳ 商品网格（2 列） | — | 点击卡片（**仅 `currentPoints >= price` 时可点**） | 只读 |
| ↳ ↳ 商品详情底部弹窗 | — | 取消 / 立即兑换 | 立即兑换 → 见下 |
| ↳ 购买按钮 | — | `currentPoints >= price` 时可点 → 弹确认框 | — |
| ↳ ↳ 确认购买 AlertDialog | — | 取消 / 购买 | **购买** → 事务：`UPDATE user_points` + `INSERT points_records(shop_purchase)` + `INSERT purchased_items` |
| ↳ FAB ➕ | — | 打开添加商品底部弹窗 | — |
| ↳ ↳ 添加商品表单 | — | 名称/描述/价格/图标(28)/颜色(19) → 添加 | `INSERT INTO shop_items` |
| ↳ 「我的仓库」链接 | — | 跳转仓库页 | 只读 |
| **我的 → 我的仓库** | `/warehouse` | — | `initState` 埋点 |
| ↳ 分组卡片 | — | 查看详情 / 使用 | **使用** → `DELETE FROM purchased_items WHERE id = ?`（删 `items.last`，最旧那条） |
| ↳ ↳ 详情抽屉 | — | 列出全部条目，逐条可删 | 同上 |
| ↳ ↳ ↳ 确认使用 AlertDialog | — | 取消 / 确认使用 | `DELETE FROM purchased_items` |
| ↳ 空态 | — | — | — |

### E.3 标签

| 页面/入口 | 路由 | 可执行操作 | 数据变化 |
|---|---|---|---|
| **设置 → 标签管理** | `MaterialPageRoute` push `TagManagementPage` | — | `initState` → `TagProvider.initialize()` |
| ↳ 系统标签分组 | — | **无操作**（`trailing: null`） | 只读 |
| ↳ 自定义标签分组 | — | PopupMenu：编辑 / 删除 | — |
| ↳ ↳ 编辑标签对话框 | — | 改 name / color（16 色板）→ 保存 | `UPDATE tags SET ... WHERE id = ?`（**不校验重名**） |
| ↳ ↳ 删除标签确认框 | — | 取消 / 删除 | `DELETE FROM tags WHERE id = ?` **+** `DELETE FROM task_tags WHERE tag_id = ?` |
| ↳ AppBar ➕ / FAB ➕ | — | 打开添加对话框（**两个入口等价**） | — |
| ↳ ↳ 添加标签对话框 | — | name / color → 添加 | `INSERT INTO tags` |
| ↳ 空态 | — | — | — |

**任务侧**（tasks 模块，仅标注）：任务表单提交 → `setTagsForTask(taskId, tagIds)` = `DELETE FROM task_tags WHERE task_id = ?` + 逐条 `INSERT OR IGNORE`；批量改标签 → 同一函数。

### E.4 回收站

| 页面/入口 | 路由 | 可执行操作 | 数据变化 |
|---|---|---|---|
| **我的 → 数据管理 → 任务回收站** | `MaterialPageRoute` push `RecycleBinPage` | — | `initState` → `loadRecycledTasks()` |
| ↳ 卡片 | — | 🔄 恢复（弹确认）/ 🗑 永久删除（**无确认**） | — |
| ↳ ↳ 恢复确认（非循环） | — | 取消 / 恢复 | 事务：`INSERT INTO tasks`（**写回原 `task_id`**，非自增新 id）+ `DELETE FROM recycled_tasks WHERE id = ?`（H1） |
| ↳ ↳ 恢复确认（循环） | — | 取消 / 仅恢复当天 / 恢复循环 | **仅恢复当天**：`DELETE FROM recycled_tasks` + `INSERT INTO tasks`（`recurrence='none'`）；**恢复循环**：同非循环 + 触发循环生成 |
| ↳ AppBar 🧹 | — | 清空（弹确认） | — |
| ↳ ↳ 清空确认 | — | 取消 / 清空 | `DELETE FROM recycled_tasks`（全表） |
| ↳ 空态 | — | — | — |

**删除任务**（tasks 模块，仅标注）：单条/批量删除 → 事务：`INSERT INTO recycled_tasks` + 裁剪至 ≤10 条 + `DELETE FROM tasks WHERE id = ?`（**不清理 `task_tags`**）。

### E.5 数据导出页（跨模块读路径，规格此前遗漏）

**我的 → 数据导出**（`lib/modules/profile/pages/data_export_page.dart`）。用户勾选要导出哪些数据 → 打包成 JSON → 通过系统分享。

| 开关 | 调用的 DB 方法 | 落到 JSON 的键 |
|---|---|---|
| 任务 | `getAllTasks()` | `tasks` |
| 标签 | `getAllTags()` | `tags` |
| 积分 | `getUserPoints()` | `points`（单对象，非数组） |
| 商城 | `getAllShopItems()` + `getAllPurchasedItems()` | `shopItems` + `purchasedItems` |
| **回收站** | **`getRecycledTasks()`** | `recycledTasks` |

固定字段：`exportVersion: 1`、`exportDate: <nowIso>`。文件名 `noteapp_export_<timestamp>.json`（⚠️ 前缀是 **`noteapp`** 不是 `v5`）。

> ⚠️ **这是 `getRecycledTasks` 唯一的生产调用方**（`data_export_page.dart:300`），也正是 review 指出我原规格把它误判为死代码的原因。
>
> **M1 若不实现数据导出 → 功能缺失。** 若实现，`recycled_tasks` 必须包含在导出范围内，且**必须提供 `getRecycledTasks()`**（不能因为「回收站逻辑在 mixin 里是死代码」而不实现）。

---

## F. RN 侧实现要点速查

| # | 要点 | 依据 |
|---|---|---|
| F1 | **同步查询必须 `db.executeSync(...)`**，`execute` 是 async | `rn/src/db/index.ts` 全部用 `executeSync` |
| F2 | 积分余额变更**一律用 `UPDATE ... SET points = points ± ?`**，绝不读出来在 JS 里算 | A.2 |
| F3 | 余额校验**下推到 `WHERE points >= ?`**，靠 `affectedRows > 0` 判成败，不用先 SELECT。
⚠️ **实现约束（T3）**：op-sqlite 的 `executeBatch` 只返回**整批总** `rowsAffected`，**拿不到逐条结果**——
所以凡是「要靠 affectedRows 判成败」的场景（余额校验）**必须用 `db.transaction()` + `tx.execute()`**，
不能用 `writeBatch`/`executeBatch`。否则会出现「扣了分但流水没写」而事务照样提交。 | A.2 / B.3 |
| F4 | `overdue_deduct` **不传余额校验**（允许负余额）；`shop_purchase` / `scratch_cost` **传** | A.7 |
| F5 | 商城兑换三步写入**必须同一事务**，任一步失败整体回滚 | B.3 |
| F6 | 逾期扣分：**先扣分 → 再 `UPDATE tasks SET is_deducted = 1`** | A.5 |
| F7 | 逾期判定用 `cpl_time < 今天00:00`（不含今天），**不是 `< now`** | A.5 |
| F8 | `markTaskDeducted` **无条件执行**（`rewardPoints == 1` 时不扣分但置位） | A.5 |
| F9 | 结算幂等靠 `ORDER BY id DESC LIMIT 1`（**按主键不按时间**），无唯一索引 | A.4 |
| F10 | 冲销金额取**历史流水的 points**，不是当前 `rewardPoints` | A.4 |
| F11 | 回收站**上限 10 条**，按 `deleted_at DESC` 裁剪，**无时间过期** | D.3 |
| F12 | ⚠️ **【作废 · Flutter 现状】** 恢复任务不搬原 id（自增新 id），导致 `related_id` / `task_tags` 悬空 → **可重复刷分**。**RN 侧按 H1 写回原 id 修掉**（见 D.4） | D.4 |
| F13 | **回收站逻辑一律参考 `TaskRepository`，不要照着 `DatabaseTaskMixin` 写**（它不搬 `loop_id`）。**但不是整个文件都别参考** —— `getRecycledTasks` / `getAllTasks` 是活代码，数据导出页依赖 | D.2 / D.8 / E.5 |
| F13a | ⚠️ **回补出的循环实例不会被扣积分** —— 逾期 SQL 硬编码 `recurrence = 'none'`（`task_repository.dart:253`），循环实例一律被排除。所以恢复循环任务触发大规模回补的危害是**列表污染 + 数据膨胀**，**不是资金损失**。这是「照搬回补」风险较低、可以接受的关键依据 | D.4 |
| F13b | ⚠️ **批量删除会即时丢任务** —— `batchDeleteTasks` 逐条同步「插入+裁剪到 10」，删 15 个会**当场丢 5 个**，无提示 | D.3 |
| F14 | 删标签**手动清** `task_tags`；删任务**移入回收站时不立即清**，但**宿主确定消失时同事务清**（裁剪 / 清空 / 单条永久删除 / 批量删循环任务 —— V1 补充） | C.3 / X3 |
| F15 | 商城和标签**都在「表空时自动播种」**，删光后重启会复活 | B.1.2 / C.3 |
| F16 | `tags.color` 是 `'#RRGGBB'` 字符串（解析时拼 `FF`）；`color_value` 是 ARGB 整数 | B.1 / C.2 |
| F17 | 标签颜色解析**必须 try/catch 兜底为蓝色** | C.2 |
| F18 | `points_records.type` 有 **7 种**，明细页要能渲染 `shop_purchase` / `scratch_cost` | A.3 |
| F19 | `shop_purchase` 的 `related_id` → `shop_items.id`（**不是** `purchased_items.id`） | B.3 |
| F20 | 明细页**只取最近 50 条**，无分页、无汇总统计 | A.8 |
| F21 | 仓库页按**快照 name 字符串**分组，不是 `shop_item_id` | B.5 |
| F22 | 仓库「使用」删的是 **`items.last`（最旧）**，卡片显示的是 `items.first`（最新） | B.5 |
| F23 | 商品**无库存**，**无编辑 UI**（`updateShopItem` 无调用方） | B.4 / B.8 |
| F24 | `task_tags` 写入用 `INSERT OR IGNORE`，复合主键天然去重 | C.1 |
| F25 | 标签重名：UI 层大小写不敏感、DB 层 UNIQUE 大小写敏感（**不一致**）；编辑时不校验重名 | C.3 |
| F26 | `tags.icon` / `tasks.priority`（回收站卡片）是**死数据 / 未渲染** | C.3 / D.6 |
| F27 | **不要照抄** `modules/points/pages/points_page.dart`（硬编码假数据 + 零引用） | G3 |
| F28 | 时间统一用 `nowLocalIso()`（`rn/src/db/pomodoro.ts`），本地时间手工拼串 | schema-v3 §1 |

---

## G. 代码与文档不一致清单

> 裁决：**以代码为准**（`schema-v3.md §9` 自己的约定）。本文档已按代码修正。

| # | 文档说法 | 代码真实行为 | 建议 |
|---|---|---|---|
| G1 | `schema-v3.md §3.3` + `business-rules.md §1`：`points_records.type` 共 **5 种** | 实为 **7 种**，多出 `shop_purchase`（`database_purchase_mixin.dart:50`）与 `scratch_cost`（`:109`） | **改文档**。两文档都漏了，且漏的两个是**商城与刮刮乐的主流水类型** |
| G2 | `business-rules.md §1.3`：逾期条件 `cpl_time < now` | `cpl_time < 今天00:00`（生效路径 `task_repository.dart:247`，变量名 `endOfDay` 但无 `+1 day`），**今天到期不扣分** | **改文档**为「早于今天 00:00」 |
| G3 | `schema-v3.md §2.4`：单行表有 `CHECK` / 约定 | `user_points` **无 `CHECK (id = 1)`**（`pomodoro_settings` 才有，`database_schema_mixin.dart:160`）；单行性纯靠代码约定 | **改文档**，或**加约束**（但会与旧库冲突，建议只改文档） |
| **G4** | `business-rules.md §6` 第 1 条待核实：扣分是否允许负余额 | **允许**。`overdue_deduct` 不传 `requireAtLeast`，`WHERE` 只判 `id = 1`（`task_settlement_mixin.dart:70`） | **改文档**，从「待核实」移到「已确认：允许负余额」 |

### G4b · 🔴【实现红线，非缺陷】`is_deducted` 不得在恢复时归零

> **V5 裁决：本条不是缺陷，是实现约束。** 缺陷要问「要不要修」，约束只问「会不会踩」。它已在红线清单里，不留在缺陷列表讨论优先级。

**机制（确定成立）**：逾期扣分与完成结算走**两条完全独立的查询**：

| 用途 | 调用点 | SQL | 幂等语义 |
|---|---|---|---|
| 完成 / 取消完成 | `_settleTaskCompleted` → `getLatestPointsRecord` | `WHERE related_id = ? AND type IN ('task_complete','task_uncomplete')` `ORDER BY id DESC LIMIT 1` | 取**最近一条** |
| **逾期扣分** | `_shouldHandlePoints` → `hasPointsRecordByTypeAndRelatedId`（`task_settlement_mixin.dart:13`） | `WHERE type = 'overdue_deduct' AND related_id = ?` | 只问「**有没有过**」 |

两者除 `related_id` 外**无任何交集**——修好结算那条查询，**不会**让逾期扣分变得幂等。

**🔴 红线**：**修复 H1（恢复时写回原 id）时，绝不能顺手把 `is_deducted` 置 0。**

一旦置 0，两道门**同时**失效（`is_deducted = 0` 的门开了 **且** `related_id` 已变查不到旧流水）→ 真扣钱；且逾期扣分**不传 `requireAtLeast`**（G4）、余额无下限 → **资金损失**。

#### 双向独立验证（结论一致：均不触发）

`is_deducted` 在各环节的流转：

| 环节 | `is_deducted` |
|---|---|
| 移入回收站 | 原样保留 |
| `RecycledTask.fromMap`（`task_model.dart:192`） | 正确读回 |
| `restoreTaskFromRecycle`（`task_repository.dart:361`） | 正确还原 |
| 编辑表单（`task_form_submit_mixin.dart:28`） | **显式继承原值** |
| 循环实例（`task_scheduler_service.dart:97`） | **`false`** ⚠️ 但 `recurrence != 'none'`，被 `getOverdueTasks` 的 `WHERE recurrence = 'none'` **直接排除**，不可达扣分循环 |

| 来源 | 查了什么 | 结论 |
|---|---|---|
| general-purpose-2 | `fromMap` → `restore` → 表单 → 循环更新的 **Dart 链路** | 全链路保留 |
| general-purpose-1 | **SQL 字面量穷举** + RN 实际代码 | 无归零路径 |

**⇒ Flutter 侧与 RN 侧均无归零路径**（RN `recycleRepo.ts:263` / `:342` 均为 `row.is_deducted ?? 0` 原值透传；`:307-318` 有主键冲突显式检查并回滚）。

> ✅ **红线当前状态：未触发，且需持续保持。** 归零只可能来自 RN 侧新增的批量重置入口——**将来若新增任何「批量重置任务」功能，必须显式声明是否影响 `is_deducted`**。

**修复 H1 时仍须覆盖三个 type**：

```sql
UPDATE points_records SET related_id = :newId
 WHERE related_id = :oldId
   AND type IN ('task_complete', 'task_uncomplete', 'overdue_deduct');  -- ← 漏第三个则重复扣分照旧
```

| G5 | `business-rules.md §5` 说顺序敏感三处，未展开 | 三处的确切位置与失败后果见 A.5；**第 ③ 处（循环任务）本文未展开**，且发现恢复循环任务会触发大规模回补（D.4） | **补文档** |
| G6 | `schema-v3.md §2.2`：`loop_id` 是 v3 补的，循环任务恢复后能继续生成 | **正确**，但需注明：只有 `TaskRepository` 这条生效路径读写 `loop_id`；`DatabaseTaskMixin.moveTaskToRecycleBin` **不写** `loop_id`（死代码） | **补注**死代码警告，避免 RN 侧参考错文件 |
| G7 | `schema-v3.md §5` 第 4 条：`task_tags`「很可能有孤儿行」 | **确认成立**，根因已定位：**删任务时不清理**（`task_repository.dart:188` 后无 `task_tags` 操作；`grep task_tags lib/modules/tasks/` 零命中）。删标签**有**清理 | **补文档**写明根因与不对称性 |
| G8 | `schema-v3.md §2.5`：`purchased_items` 快照「改名/改价后历史记录不受影响」 | **正确**。但补一条：仓库页**按快照 `name` 分组**，改名会分裂成两组、重名会合并成一组 | **补文档** |
| G9 | `schema-v3.md §6` 第 1 条：`custom_prize_pool.type` 取值待实测 | 代码里 `type='goods'` 会**触发按 name 去商城匹配商品**（`business-rules.md §4.2`），这是与商城的隐藏耦合 | **补文档**该耦合关系 |
| G10 | `schema-v3.md §5` 第 2 条：`user_points` 只能有 `id=1` 一行 | 约束只存在于代码约定（见 G3）。另外 `applyPointsDeltaTxn` 的懒初始化分支在 `requireAtLeast > 0` 时会**返回 false 而不建行** | **补文档**该分支行为 |
| G11 | `schema-v3.md §7` 验收查询第 2 条：`balance == SUM(流水)` 必须成立 | 正常路径成立（`updatePoints` / `setPoints` **无 UI 入口**）。但**任务恢复后重复完成会多加一次分**（D.4①），此时两笔流水都记了，等式仍成立，但**用户实际收益超出预期** | **补文档**该已知缺陷 |
| G12 | `schema-v3.md §4` 索引清单 | **完全一致**，8 条索引逐条核对无误（`database_schema_mixin.dart:247` vs `rn/src/db/schema.ts:145`） | ✅ 无需改动 |
| G13 | `rn/src/db/schema.ts` 的 DDL | 与 `database_schema_mixin.dart` **逐列一致**（含 `color_value DEFAULT 4278190335`、`scratch_tickets` 两列无 NOT NULL）。唯一差异：`SEED_SQL` 用 `INSERT OR IGNORE` 且**不插示例任务**，Flutter 版会插 3 条示例任务 | **补文档**：全新安装时 RN 不会插入示例任务（`欢迎使用任务管家` 等 3 条） |
| G14 | ✅ **已确认**（原为「需人工确认」） | `custom_prize_pool` 有两处 DDL。**`createScratchTables` 在 `lib/` 下零调用方**（仅 `test/core/database_scratch_mixin_test.dart:35` 与 `database_business_fixes_test.dart:120` 两个测试调用）。故 `database_scratch_mixin.dart:10` 的旧 DDL 是**死代码** | **严格版 `database_schema_mixin.dart:100` 为权威**。`rn/src/db/schema.ts` 采用严格版是**正确的**，无需改动 |
| G15 | ✅ **已确认** | `scratch_win` / `scratch_refund` 的 `related_id` 是 **`NULL`**（`scratch_play_mixin.dart:202,225` 未传 `relatedId`）。`business-rules.md §3.3` 说「刮刮乐类 → `scratch_tickets.id` 或奖池 id」**只对 `scratch_cost` 成立** | **改文档**。且明确：刮刮乐中奖/退款**无法通过 `related_id` 追溯票据**，是历史信息缺失 |
| G16 | ✅ **已确认** | `PRAGMA foreign_keys` **全仓从未开启** —— `lib/` 下唯一的 `PRAGMA` 是 `database_migration_mixin.dart:50` 的 `PRAGMA table_info(recycled_tasks)`。所以 `task_tags` 声明的 `ON DELETE CASCADE` **确定性失效**，不是「大概率没生效」 | **改 `schema-v3.md §2.3`** 的「大概率没有真正生效」为「确定未生效」 |

---

## H. 待人工确认清单

| # | 问题 | 为什么阻塞 | 建议 |
|---|---|---|---|
| H1 | **任务恢复后 id 变化导致重复加分**（D.4①） | 影响积分正确性，用户可主动利用 | ⚠️ **修正：复用原 id 不是「顺手修好」**。详见下方 X1 —— 复用 id 会让旧流水**重新认领**该任务，方向与现状**完全相反**。**M1 照搬（接受重复加分）**，若要修必须与 tasks 模块同一个 PR 一起改，否则两边假设不一致比现状更糟 |
| H2 | **恢复任务是否要恢复标签**（D.4②） | 初判「技术上无法恢复」有误——`recycled_tasks` 确实无标签快照列，但**不需要快照**：`task_tags` 行一直在，配合 H1 写回原 id 即自动恢复 | **有条件自动恢复**（V4）：H1 成立 + 条目仍在回收站内。**无需 schema 变更** |
| H3 | **恢复循环任务触发大规模回补**（D.4③） | 删 3 个月前的每日任务再恢复 → 生成 90+ 实例 | **已与 tasks 模块达成一致：M1 照搬，不夹「今天起」**。危害仅为列表污染 + 数据膨胀，**不扣积分**（F13a）。夹「今天起」会让同一份数据在 Flutter / RN 上跑出不同列表，**迁移期无法对账**，代价更大。建议先在真库跑 `SELECT COUNT(*) FROM tasks WHERE recurrence != 'none' AND cpl_time < date('now','localtime');` 评估规模 |
| H4 | **删任务是否清理 `task_tags`**（C.3） | 「照搬不清理」是**中途结论，已被 V1 取代**：不立即清理、永久删除时同事务清理 | **V1**：移入时不清理（保 H2）；**四条永久删除路径**（裁剪/清空/单条永久删除/批量物理删除）同事务清理。`purgeOrphanTaskTags()` 降级为兜底，**不自动调用** |
| H5 | **`markTaskDeducted` 无条件执行**（A.5） | `rewardPoints == 1` 的任务不扣分但永久标记 | 照搬并注释；若修则属于行为变更 |
| H6 | **仓库页按 name 分组**（B.5） | 商品改名分裂分组、重名合并分组，均可能是用户可见的怪现象 | 照搬；如要修正属行为变更 |
| H7 | **`shop_purchase` 的 `related_id` 指向 `shop_items.id`**（B.3） | 若按「指向 `purchased_items.id`」理解，对账 SQL 会全错 | 已确认是 `shop_items.id`，RN 侧照搬 |
| H8 | **编辑标签名撞 UNIQUE 会抛未捕获异常**（C.3） | 用户会遇到崩溃 | RN 侧加 try/catch + 友好提示（属修复，不改正常路径行为） |
| H9 | ~~`custom_prize_pool` 两份 DDL~~ **✅ 已关闭** | 已确认 `createScratchTables` 在 `lib/` 下零调用方，旧 DDL 为死代码，严格版权威。见 G14 | 无需再确认 |
| H14 | **`settings` 与 `pomodoro_records` 两张表本规格零覆盖** | `settings`（键值表）与 `pomodoro_records`（番茄钟记录，含 `related_task_id`）**不在本文范围**——前者由 settings 模块负责，后者属番茄钟模块。但 `pomodoro_records.related_task_id` 是 D.4① 的**第四个悬空引用**，已在那里交代 | RN 实现本四模块时**不需要**动这两张表；若实现番茄钟，需与本文 D.4① 的结论对齐 |
| H10 | **埋点（`StatisticService`）是否迁移**（B.7） | 本地存储，无功能依赖 | 倾向不迁移；如迁移需一并实现 `statistic_cache` 2000 条上限 |
| H11 | **回收站文案「保留一段时间」不准确**（D.3） | 用户预期与「只留 10 条」不符 | 建议改为「仅保留最近 10 条」（文案修正，行为不变） |
| H12 | **永久删除无二次确认**（D.6） | 误触即永久丢失 | 建议加确认（交互修正，行为不变） |
| H13 | **RN 全新安装不插 3 条示例任务**（G13） | 与 Flutter 版首装体验不一致 | 建议补上（纯新增，不影响迁移路径） |

---

## X. 与 tasks 模块的联合裁决（跨模块，2026-10-20）

本节记录两个模块就交叉依赖达成的共识。**两份规格必须保持表述一致**，否则 RN 实现方会拿到互相矛盾的假设。

### X1 · 恢复任务的 id 复用 —— 「修好」比现状更糟

**现状（照搬）**：恢复后拿新 id → `getLatestPointsRecord(新id)` 查不到 → 认为「从未结算」→ **重复加分**。

**曾考虑的修法**：恢复时插回 `recycled_tasks.task_id`，同步 `UPDATE task_tags SET task_id = ?`。**已否决**，理由：

| | 现状（id 变化） | 复用 id |
|---|---|---|
| 标签关联 | 丢失（孤儿） | ✅ 恢复 |
| 恢复一个**已完成**的任务后再次点完成 | **重复加分**（`related_id=新id` 查不到旧流水） | **不再加分**（`related_id=原id` 命中旧流水，被判「已加分」） |
| `pomodoro_records.related_task_id` | 关联不上 | ✅ 恢复 |

> 🔍 **关键**：两种修法的方向**完全相反**。复用 id 后，`task_settlement_mixin.dart:17` 的幂等判定会**失配**——旧流水会「重新认领」这个任务。而一旦积分侧和任务侧对判定口径理解不一致，**比现在的已知缺陷更糟**。
>
> ⚠️ **「仅恢复当天」是复用 id 方案的绕过口**（review 发现，已核实）：`recycle_bin_page.dart:232` 走的是 `deleteFromRecycle` + `addTask`，**不经过 `restoreTaskFromRecycle`**，所以它**必然产生新 id**。
> 这意味着：**若将来要修 H1，必须同时改「仅恢复当天」分支**，否则用户改点这个按钮就能绕过修复、继续刷分。
>
> ⚠️ **不要依赖 AUTOINCREMENT 作为「显式写回 id 不会冲突」的保证**。`AUTOINCREMENT` 保证的是「**自动分配**时不复用已删除 id」，**不保证显式插入**一个已占用的 id 不冲突——显式插入直接走主键约束，撞了就是 `UNIQUE constraint failed: tasks.id`。修复实现里必须对 `tasks.id` 做显式存在性检查，撞了回滚 + 提示。
>
> **裁决：M1 照搬现状。** 若将来要修，**必须同一个 PR 同时改任务恢复、积分幂等判定、且覆盖「仅恢复当天」分支**，三处假设一起改。

### X1b · `overdue_deduct` 的双查询结构 —— 🔴 实现红线（V5）

`overdue_deduct` 走的是**另一个查询** `hasPointsRecordByTypeAndRelatedId('overdue_deduct', taskId)`（`task_settlement_mixin.dart:13`），与 `getLatestPointsRecord` 无关。所以修好 X1 的 ①② 后，**若不把 `is_deducted` 保持原值，两道门会同时失效** → 真扣钱。

**V5 裁决：定性为实现红线，不是缺陷。** 定级经历 🔴 缺陷 → 🟡 → 🔴 实现红线（三次修正，均由核实推动）。

**当前状态：未触发且需持续保持** —— 双向独立验证（general-purpose-2 的 Dart 链路 + general-purpose-1 的 SQL 字面量穷举与 RN 实际代码）结论一致：两侧均无归零路径。

**唯一风险来源**：将来 RN 新增「批量重置任务」入口。**必须显式声明是否影响 `is_deducted`。**

**修复 H1 时** `UPDATE points_records SET related_id = :newId` 的 WHERE **须含全部三个 type**（见 D.4①）。完整证据表见 **G4b 专节**。

### X1c · 回收站裁剪会消灭「找回原 id 的唯一线索」

`recycled_tasks.task_id` 是 D.4① 修复方案的唯一依据。但**裁剪会物理删除回收站行**（`task_repository.dart:202-208`，无任何连带处理），行一旦被裁掉：

- 该任务的 `points_records` **永久悬空**，且**永久无法修复**（线索没了）；
- **H1/X1 的修复只能救「还在回收站里」的任务**。

> 🔍 这是唯一会造成 `points_records` **永久**失去修复可能性的操作。设计修复方案时必须把「裁剪」也纳入考虑，或接受「被裁剪的任务永久无法对账」。

### X2 · 循环回补 —— 不夹「今天起」

`task_recycle_mixin.dart:15` 用回收站存的**原始 `cplTime`** 触发回补（`business-rules.md §2.2`：无下界）。恢复 3 个月前的每日任务 → 生成 90+ 实例。

**裁决：M1 照搬，不夹到「今天起」。** 两条理由：

1. **不涉及资金** —— 逾期 SQL 硬编码 `recurrence = 'none'`（`task_repository.dart:253`），回补出的循环实例**不会被扣分**。危害仅为列表污染 + 数据膨胀。
2. **夹「今天起」会让迁移期无法对账** —— 同一份数据在 Flutter 和 RN 上跑出不同列表，比「列表多几十行」更麻烦。

先在真库跑这条评估规模：
```sql
SELECT COUNT(*) FROM tasks WHERE recurrence != 'none' AND cpl_time < date('now','localtime');
```

### X3 · `task_tags` 孤儿行 —— ⚠️**原「照搬不清理」裁决已被 V1 取代**

根因：删任务**不立即**清理 `task_tags`（`task_repository.dart:188` 之后无任何 `task_tags` 操作）。删标签**有**清理，所以是不对称的。

**原裁决（已作废）**：「M1 照搬不清理，孤儿归迁移期一次性处理」。
作废理由：它把 `schema-v3.md §7` 第 1 条「`task_tags` 行数迁移前后完全一致」当成了硬约束，
于是选择让孤儿无限累积——**代价大于收益**。

**现行裁决（V1）**：不立即清理、**永久删除时同事务清理**，覆盖四条路径：

| 路径 | 触发时机 |
|---|---|
| 回收站裁剪（`_cleanupRecycledTasksTxn`） | 移入第 11 个导致最旧条目被物理删除 |
| 清空回收站（`clearRecycleBin`） | 整表清空 |
| 单条永久删除（`deleteFromRecycle`，`task_repository.dart:380`） | V1 补充才补上 |
| **批量删除循环任务**（`deleteTask(deleteAll: true)`，`task_repository.dart:148`） | **V1 初版漏了，V1 补充才补上**。该路径**物理删除、不进回收站**，最容易被遗漏 |

**为什么「§7 行数一致」不再构成约束**：迁移验收在**迁移完成时立即执行**，
而上述清理只在**用户触发删除**时发生——两者不在同一时点，不需要互相让步。
`purgeOrphanTaskTags()` 降级为**兜底**，不自动调用。

### X4 · ⚠️ `schema-v3.md` §5.4 与 §7 自相矛盾（文档 bug，会卡住验收）

| 位置 | 说法 |
|---|---|
| §5 第 4 条 | 「`task_tags` **很可能有孤儿行**，迁移时不要假设外键已清理，应先跑 §7 的孤立行检查」 |
| §7 查询 3 | 孤儿关联「**应为 0**」 |
| §7 判定标准 | 1、2、3、5 必须**完全一致** |

**这两条不可能同时成立**：若旧库真有孤儿行（§5.4 说的就是这），§7 第 3 条「应为 0」必然失败，**迁移验收过不去**。

**⚠️ 更精确的触发条件（与 general-purpose-1 交叉核对时补充，已采纳）**：两条矛盾只在**旧库确有孤儿**时才卡住。若真库跑出来是 0，两条自洽、不必改。**先验证再决定是否动契约文件。**

**建议修正（X4 + X3 合并，共两条要改，不是一条）**：

| 要改的 | 现状 | 改为 | 触发条件 |
|---|---|---|---|
| §7 查询 3 | 孤儿关联「**应为 0**」 | 「**迁移前后孤儿数一致**」 | 仅当旧库确有孤儿 |
| §7 查询 1 | `task_tags` 行数**完全一致** | 「**一致，或差异有明确书面解释**」 | **必然要改**——只要引入 `purgeOrphanTaskTags()`，行数必然减少 |

> 🔍 **第二条是无条件的**：`purgeOrphanTaskTags()` 一旦在 M1 落地，删除的孤儿行会让 RN 库行数 < 旧库，§7 第 1 条**必然失败**。所以即使旧库孤儿数为 0（第一条不用改），**第二条也必须改**。
>
> **性质**：文档问题，非代码问题。`schema-v3.md` 是全组共用契约文件，**改动需 team-lead 拍板**。

### X5 · RN 侧 `recurrence.ts` 的 monthly `guard < 240` 是 RN 独有保护

`rn/src/core/recurrence.ts:75` 的 monthly 循环有 `guard < 240` 迭代上限，**Flutter 侧没有对应保护**。

- **影响**：模板 `cplTime` 早于约 20 年时，RN 的 monthly 回补会**提前截断**，与 Flutter 结果不一致。
- **对本模块的影响**：仅通过「恢复循环任务」间接影响积分/回收站，**不涉及积分金额**。
- **注意**：`guard < 240` ≈ 20 年 × 12 月。这个上限在正常数据下（模板不会早于 20 年）**永不触发**，属于防御性代码。要不要保留、要不要对齐，tasks 模块定。

### X6 · `DatabaseTaskMixin` 双份实现的准确边界

`DatabaseTaskMixin` 与 `TaskRepository` 有同名方法双份实现。按**读写侧**划分，比「整个文件死/活」更准确：

| 侧 | 方法 | 状态 | RN 实现参考 |
|---|---|---|---|
| **回收站写入侧** | `moveTaskToRecycleBin`(:205)、`deleteTaskWithoutRecycle`(:238)、`_cleanupRecycledTasksTxn`(:244)、`restoreTaskFromRecycle`(:263)、`deleteFromRecycle`(:305)、`clearRecycleBin`(:314) | ❌ **6 个全是死代码** | **只能参考 `TaskRepositoryImpl`**。核心差异：mixin 版**不搬 `loop_id`**，照抄会丢循环链 |
| **读取侧** | `getRecycledTasks`(:257)、`getAllTasks`(:37) | ✅ **都活着**（数据导出页调用） | 两版行为一致，**实现任一即可** |

> ✅ 实测结论：两个 `getRecycledTasks` 的 SQL **字符级相同**（`SELECT * FROM recycled_tasks ORDER BY deleted_at DESC`），均走 `RecycledTask.fromMap`（15 字段），**唯一差异是数据库句柄来源**。此前流传的「两版返回字段数不同」说法**不成立**。
>
> **一句话**：「勿参考 mixin」只适用于**回收站写入侧**；读取侧照抄无风险。

---

## I. 相关文件索引（供 RN 侧对照）

**规格来源（Dart，只读）**
- 积分：`lib/modules/points/models/points_model.dart`、`lib/core/services/database/database_points_mixin.dart`、`lib/providers/points_provider.dart`
- 商城：`lib/modules/shop/models/shop_model.dart`、`lib/modules/shop/repositories/shop_repository.dart`、`lib/core/services/database/database_shop_mixin.dart`、`lib/core/services/database/database_purchase_mixin.dart`、`lib/providers/shop_provider.dart`、`lib/modules/shop/pages/{shop_page,warehouse_page}.dart`、`lib/modules/shop/widgets/add_shop_item_form_widget.dart`
- 标签：`lib/modules/tag/models/tag_model.dart`、`lib/core/services/database/database_tag_mixin.dart`、`lib/providers/tag_provider.dart`、`lib/modules/tag/pages/tag_management_page.dart`
- 回收站：`lib/modules/tasks/pages/recycle_bin_page.dart`、`lib/modules/tasks/repositories/task_repository.dart`（`:137` deleteTask、`:337` restoreTaskFromRecycle、`:380` deleteFromRecycle、`:392` clearRecycleBin）、`lib/providers/mixins/task_recycle_mixin.dart`
- 结算：`lib/providers/mixins/task_settlement_mixin.dart`（82 行，全模块核心）
- DDL：`lib/core/services/database/database_schema_mixin.dart`

**RN 侧已就绪（只读参考）**
- `rn/src/core/points.ts` —— 结算纯函数，`resolveCompletion` / `resolveUncompletion` / `resolveOverdueDeduction` **可直接复用**，与本文 A.4 / A.6 一致
- `rn/src/db/schema.ts` —— DDL，与 Flutter 版逐列一致
- `rn/src/db/index.ts` —— `openDatabase()` / `executeSync` 用法 / `readBalance()` / `countOrphans()`
- `rn/src/db/pomodoro.ts` 的 `nowLocalIso()` —— 时间戳生成，四模块统一用这个
