# 业务规则基线 · 迁移重写对照表

> 用途：RN 重写时**逐条对照**的行为规格。UI 可以重画，这些规则不能变——变了用户会看到「积分不对」「循环任务断了」「统计少了」。
> 来源：`lib/providers/mixins/task_settlement_mixin.dart`、`lib/modules/tasks/services/task_scheduler_service.dart`、`lib/providers/mixins/scratch_play_mixin.dart`、`lib/core/services/statistic_service.dart`、`lib/modules/games/pages/game_host_page.dart`。
> 配套：`docs/migration/schema-v3.md`（数据契约）。

---

## 1. 积分结算

### 1.1 完成任务（加分）

| 项 | 规则 |
|---|---|
| 触发 | 任务被标记完成 |
| 前置 | `task.id != null` 且 `rewardPoints > 0` |
| 幂等 | 取该任务**最近一条**结算流水（`task_complete` / `task_uncomplete`）：若它是 `task_complete` → 不加分；否则加分 |
| 写入 | `points_records(points=+rewardPoints, type='task_complete', related_id=task.id)` |
| 可逆性 | 取消完成会写冲销流水，所以**再完成可以再次加分**，不会「取消过一次就永久不给分」 |

### 1.2 取消完成（冲销）

| 项 | 规则 |
|---|---|
| 前置 | 最近一条结算流水必须是 `task_complete`，否则不动 |
| 金额 | **取那条加分流水的 `points`**，不是任务当前的 `rewardPoints`（完成期间改过奖励值也能对称冲销） |
| 写入 | `points_records(points=-该值, type='task_uncomplete', related_id=task.id)` |

### 1.3 逾期扣分

| 项 | 规则 |
|---|---|
| 条件 | `cpl_time < now` 且 `!isOK` 且 `!isDeducted` 且 `rewardPoints > 0` |
| 金额 | `floor(rewardPoints / 2)`，为 0 则不扣 |
| 幂等 | 已有 `overdue_deduct` 记录则跳过 |
| **顺序（红线）** | **先扣分成功，再置 `is_deducted = 1`**。反过来一旦扣分失败，任务会被永久漏扣 |
| 写入 | `points_records(points=-扣分, type='overdue_deduct', related_id=task.id, description='逾期任务扣除: <title>')` |

> 待核实：扣分是否允许余额为负（见 §6）。RN 侧不要擅自加「余额不足则跳过」的逻辑。

---

## 2. 循环任务

### 2.1 loopId

格式：`loop_<毫秒时间戳>_<0–9999 随机数>`。同一系列的所有实例共享。

### 2.2 生成窗口与规则

- **上界**：`now + 15 天`（含边界日）。**没有下界**——生成从模板 `cplTime` 当天开始；模板很旧时会**从旧日期逐日回补**（实测：`cplTime=1/1`、`now=1/31` → 生成 46 天）。
- **起点**：模板任务的 `cplTime` 当天 00:00。
- **daily**：逐日 +1 天。
- **weekly**：先把日期推进到与模板 `cplTime.weekday` 相同的星期几，再每次 +7 天。
- **monthly**：按模板 `cplTime.day` 取当月同日；**当月没有该日则取月末**（如 31 号 → 2 月 28/29 号）；月末后下个月从 1 号重新计算，跨年进位。
- **其它 `recurrence`**：直接退出，不生成。

### 2.3 去重（关键）

同一 `loop_id` + **同一天**（`[当天 00:00, 次日 00:00)`）已存在实例 → 跳过。**不是按 title 去重**。

### 2.4 新实例的字段

`id` 置空、`cplTime = 目标日`、`isOK = false`、`completedAt = null`、`isDeducted = false`；其余字段（title/description/rewardPoints/priority/isWord/recurrence/loopId）复制模板。

> **标签不复制**：插入只写 `tasks` 表，不写 `task_tags`。重写时保持同样行为，否则「循环任务带标签」会变成新特性。

### 2.5 模板选择

对每个 `loopId` 取**最早**的一条作为模板；`loopId` 为空的历史任务用复合键
`title||description||recurrence||isWord||rewardPoints` 归并。

### 2.6 事务

整批生成在**单个事务**内完成。

---

## 3. 统计

### 3.1 存储

- `SharedPreferences` 键 `statistic_cache`，JSON 数组，**上限 2000 条**，超出丢弃最旧的。
- 每次上报都是「读整份缓存 → 追加 → 重写整份」——这就是写放大，也是下面节流存在的原因。

### 3.2 游戏分数节流

| 项 | 规则 |
|---|---|
| 触发 | 游戏内每次得分上报 |
| 节流 | 同一局内**每 5 秒最多写一次** |
| 额外条件 | 分数必须**严格大于**上次已写的分数，否则不写 |
| **终局例外** | `isFinal = true` 时**不受 5 秒限制**，保证本局最终分数一定入账 |

> 重写时最容易错的两点：① 终局也套了节流；② 用 `>=` 而不是 `>`。

---

## 4. 刮刮乐

### 4.1 购票

- 事务内「扣积分 + 插入票据」，余额不足返回 `null` 且**零写入**（不会出现「票出了分没扣」）。
- 免费票 `costPoints = 0`，不扣分；**因此发奖失败时退款 0，不会凭空加分**。

### 4.2 开奖

| 场景 | 行为 |
|---|---|
| 空奖（`prizeType == 'none'` 或 `prizeValue <= 0`） | 不发任何奖励，正常结束 |
| `prizeType == 'goods'` | 按 `prizeName` 在商城找同名商品 → 写入 `purchased_items`；找不到则抛错 |
| 其它 | `points_records(points=+prizeValue, type='scratch_win')` |
| 发奖失败 | 退还 `costPoints`，写 `points_records(type='scratch_refund')` |
| 幂等 | 内存 `Set<int> _claimedTicketIds`，同一张票不二次发放/退款 |

> ⚠️ 幂等只在**内存**里。进程重启后该集合清空——重写时如果直接照搬，需要确认「票据揭晓后是否还能再次进入领奖路径」。建议 RN 侧改为**数据库幂等**（见 §6 待核实）。

### 4.3 揭晓与落库

`revealPrize()` 把内存票据标 `isRevealed = true`；`saveLotteryResult()` 再把票据写回库、插入一条 `lottery_records`、刷新钱包。
**钱包查询条件是 `is_revealed = 0`**，不是 `is_scratched`。

### 4.4 历史遗留

`scratch_tickets.is_scratched` 全库扫下来**没有任何写入点**（恒为 0）。重写时**不要**用它判断是否已刮。

---

## 5. 顺序敏感的三处（写错就是脏数据）

1. 逾期扣分：**先扣分，后置 `is_deducted`**。
2. 刮刮乐购票：**同事务**扣分 + 出票。
3. 循环任务：**先查同日重复，再插入**（且整批一个事务）。

---

## 6. 待核实（迁移前用真库或真机确认）

| # | 问题 | 状态 | 结论 / 为什么重要 |
|---|---|---|---|
| 1 | 扣分是否允许余额为负 | ✅ **已确认** | **允许**。`overdue_deduct` 不传余额校验（`task_settlement_mixin.dart:67-76`），`UPDATE` 只有 `WHERE id = 1`；而 `shop_purchase` / `scratch_cost` 传校验。**同一套 API 两种语义**。RN 侧照搬（见 `m1-decisions.md` F4）。 |
| 2 | 刮奖幂等在重启后的真实行为 | ⏳ 未确认 | 内存 Set 丢失后可能重复领奖。**属 M3（刮刮乐）范围**，届时确认。 |
| 3 | `points_records.related_id` 在 `scratch_win` 时指向什么 | ✅ **已确认** | **是 NULL**——`scratch_play_mixin.dart:202` 与 `:225` 都没传 `relatedId`。影响对账 SQL：刮奖类流水**不能**按 `related_id` 关联。 |
| 4 | 循环任务生成时，标签是否真的不带过去 | ✅ **已确认** | **不带**——`_insertIfNotExistsTxn` 从不写 `task_tags`。⇒ **所有循环实例都无标签**，这是刻意的，不是 bug。 |
| 5 | 统计缓存的 2000 条上限是否按插入顺序截断 | ⏳ 未确认 | 影响历史统计可见范围。**属 M3（统计）范围**。 |
| 6 | 循环任务回补过去日期（上界 15 天、**无下界**） | ✅ **已裁决** | **照搬，不夹到「今天起」**（`m1-decisions.md` V13 / X2）。理由：改了会让同一份数据在 Flutter 与 RN 跑出不同列表，**迁移期无法对账**；且回补实例 `recurrence != 'none'` 被逾期 SQL 排除 → 只造成列表污染与数据膨胀，**不扣积分**。真实库实测最老循环实例 2023-11-08（约 40 个月、几十行）。**延后到 v6.x** 按真实规模收敛。 |
