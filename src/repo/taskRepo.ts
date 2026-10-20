/**
 * 任务仓储层。
 *
 * 对应 Flutter 侧 `lib/modules/tasks/repositories/task_repository.dart` +
 * `lib/modules/tasks/services/task_scheduler_service.dart`，
 * 规格见 `docs/migration/spec-tasks.md` §2 / §3 / §4。
 *
 * ── 与 recycleRepo.ts 的分工（避免同一个裁决有两份实现） ──
 *
 * 「移入回收站 / 裁剪 / 恢复 / 永久删除 / 清空」这五条路径由
 * `recycleRepo.ts` 实现（software-engineer-1 交付，已按 V6 三步加好守卫）。
 * 本文件**只做再导出**，不重复实现——理由见 `m1-decisions.md` 通则 6 第 5 条
 * 「同一裁决的状态只存一处」：两处各写一遍 SQL，正是 V6 那类
 * 「某处忘了加 `NOT IN (SELECT id FROM tasks)` 守卫」缺陷的温床。
 *
 * ⚠️ 唯一例外是 `deleteTask(deleteAll: true)`（批量物理删循环任务）：
 * 它**不经回收站**，recycleRepo 没有这条路径，归本文件（V1 补充的第四条）。
 *
 * ── 两条实现红线 ──
 *
 * 🔴 1. **恢复时绝不能把 `is_deducted` 置 0。** 逾期扣分有两道门
 *    （`is_deducted = 0` + `points_records` 按 id 查流水），是「与」不是「或」。
 *    保留原 id → 门 2 有效；若顺手置 0 → 两门同时失效 → **真扣用户积分、
 *    余额无下限保护**。本文件不实现恢复，故也不碰这一列。
 * 2. **所有 ORDER BY 补 `id` 次级键**（有意偏离，见 `m1-decisions.md`）：
 *    Dart `List.sort` 不稳定、RN `Array.sort` 稳定，照搬会让同 key 项
 *    在两版间顺序不一致。Flutter 侧只有 `getTasksForDate` 有 `id DESC`，
 *    `searchTasks` / `getTasksByDateRange` 原本没有——这里补齐。
 */

import {
  db,
  fromBool,
  isoMinute,
  localDate,
  nowLocalIso,
  queryAll,
  queryOne,
  queryScalar,
  writeBatch,
} from './base';
import { deleteTaskTagsForDeletedTasks } from './recycleRepo';
import { exec, runTransaction } from './tx';
import type { Priority, Recurrence, TaskRow } from './types';
import { moveTaskToRecycleBin } from './recycleRepo';
import { getLatestPointsRecord, insertRecord } from './pointsRepo';
import {
  generateInstanceDates,
  generateLoopId,
  instanceKey,
  type Recurrence as CoreRecurrence,
} from '../core/recurrence';
import {
  resolveCompletion,
  resolveOverdueDeduction,
  resolveUncompletion,
  type SettlementType,
} from '../core/points';

// ── 纯逻辑（可脱离 RN 环境测试） ──────────────────────────────────────────

/** `tasks` 的 13 个非 id 列，`SELECT *` 时的显式展开（避免 `SELECT *` 随表结构漂移）。 */
const TASK_COLUMNS =
  'id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence, ' +
  'completed_at, reward_points, is_deducted, created_at, priority';

/**
 * 首页/日历主查询的 `ORDER BY`——**五键，一个都不能少**（spec §2.1）。
 *
 * 顺序含义：未完成在前 → 优先级高在前 → 计划时间早在前 → 同时间新 id 在前。
 *
 * ⚠️ 最后那个 `id DESC` 是**原 Flutter 就有的**（不是本文件加的 tiebreaker），
 * 本文件补的是 `searchTasks` / `getTasksByDateRange` 那两条查询。
 */
export const ORDER_BY_FOR_DATE =
  "is_ok ASC, " +
  "CASE priority WHEN 'red' THEN 0 WHEN 'orange' THEN 1 " +
  "WHEN 'yellow' THEN 2 WHEN 'blue' THEN 3 WHEN 'white' THEN 4 END, " +
  'cpl_time ASC, id DESC';

/** 搜索/日期范围查询的 `ORDER BY`：**末尾补 `id` 次级键**（红线 2）。 */
export const ORDER_BY_WITH_ID_TIEBREAKER = 'created_at DESC, id DESC';
export const ORDER_BY_RANGE_WITH_ID_TIEBREAKER = 'cpl_time DESC, id DESC';

/**
 * 当天的半开区间 `[当日 00:00:00, 次日 00:00:00)`，用于 `cpl_time` 字符串比较。
 *
 * ⚠️ 用 `isoMinute`（精确到秒、无毫秒）而不是 `nowLocalIso`：
 * `cpl_time >= '2026-10-20T00:00:00'` 对 `'...T00:00:00.123'` 仍成立
 * （定长前缀的字典序 == 时间序），而 `<= 次日 00:00` 才不会把次日 0 点整漏进来。
 */
export function dayRange(d: Date): { start: string; end: string } {
  const start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0);
  const end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0);
  return { start: isoMinute(start), end: isoMinute(end) };
}

/** 逾期判定的边界：**当日 00:00:00**（不是 now）。 */

/**
 * 逾期上界 = 当日 00:00:00（本地）。
 *
 * ⚠️ T4 裁决：逾期口径是「**早于今天 00:00**」——今天到期不扣分。
 * Flutter 侧变量名叫 `endOfDay` 但实际值是 `Date(y,m,d)`（当天零点），
 * 这里沿用**行为**而不是那个误导的名字。
 */
export function overdueUpperBound(now: Date = new Date()): string {
  return isoMinute(new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0, 0));
}

/** `endDate` 归一化到「当日 00:00 + 1 天」，使区间**含当天整天**（spec §2.2）。 */
export function normalizeEndDate(d: Date): string {
  return isoMinute(new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0));
}

/**
 * 插入前的重复检测走哪个分支（spec §2.8）。
 *
 * - 循环任务**且** `loop_id` 非空 → 分支 A（按 loop + 当天）
 * - 其余（一次性任务，或循环但 `loop_id` 为空）→ 分支 B（按 标题 + 描述 + 当天）
 *
 * ⚠️ Flutter 用 `recurrence != 'none' && loopId != null` 判定（Kotlin/Dart 的
 * `&&` 是短路求值，不是运算符优先级问题，这里逐字照搬）。
 */
export function duplicateBranch(recurrence: Recurrence, loopId: string | null): 'loop' | 'title' {
  return recurrence !== 'none' && loopId !== null ? 'loop' : 'title';
}

/** 分支 A 的 SQL。 */
export const SQL_EXISTS_IN_LOOP =
  `SELECT id FROM tasks
      WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ?
      LIMIT 1`;

/** 分支 B 的 SQL。`description` 为 null 时用 `IS NULL`，非 null 用 `=`。 */
export const SQL_EXISTS_ON_DATE =
  'SELECT id FROM tasks WHERE title = ? AND cpl_time >= ? AND cpl_time < ?';

export function existsOnDateSql(description: string | null): string {
  return description === null
    ? `${SQL_EXISTS_ON_DATE} AND description IS NULL LIMIT 1`
    : `${SQL_EXISTS_ON_DATE} AND description = ? LIMIT 1`;
}

/** 分支 B 的参数（与 `existsOnDateSql` 的占位符一一对应）。 */
export function existsOnDateParams(
  title: string,
  description: string | null,
  day: { start: string; end: string },
): unknown[] {
  return description === null
    ? [title, day.start, day.end]
    : [title, day.start, day.end, description];
}

/** `searchTasks` 的 WHERE 子句与参数（各条件可选，按 spec §2.2 的顺序拼接）。 */
export function buildSearchWhere(q: {
  query: string;
  startDate?: Date | null;
  endDate?: Date | null;
  completionStatus?: boolean | null;
}): { sql: string; params: unknown[] } {
  const where: string[] = [];
  const params: unknown[] = [];
  if (q.query.length > 0) {
    where.push('(title LIKE ? OR description LIKE ?)');
    params.push(`%${q.query}%`, `%${q.query}%`);
  }
  if (q.startDate) {
    where.push('cpl_time >= ?');
    // startDate **不归一化**（spec §2.2），直接用它的时间串。
    params.push(nowLocalIso(q.startDate));
  }
  if (q.endDate) {
    where.push('cpl_time < ?');
    params.push(normalizeEndDate(q.endDate));
  }
  if (q.completionStatus !== null && q.completionStatus !== undefined) {
    where.push('is_ok = ?');
    params.push(fromBool(q.completionStatus));
  }
  return { sql: where.length > 0 ? ` WHERE ${where.join(' AND ')}` : '', params };
}

/**
 * 联动更新时，「这个实例要不要跟着改」的判定（spec §3.4）。
 *
 * 只联动**不早于本任务**的实例；`isDateBefore` 在 Flutter 侧只比较 y/m/d
 * （各自归零时分秒），这里显式复刻——直接比 `Date` 会把时分秒算进去而误判。
 */
export function shouldPropagate(
  instanceCplTime: string,
  sourceCplTime: string,
  sameId: boolean,
): boolean {
  if (sameId) return false;
  return dayKey(instanceCplTime) >= dayKey(sourceCplTime);
}

/** 取本地日期 `YYYY-MM-DD`（前 10 位），用于只比 y/m/d。 */
function dayKey(isoLocal: string): string {
  return isoLocal.slice(0, 10);
}

// ── 新增任务的入参 ───────────────────────────────────────────────────────

/** `addTask` 的入参。字段名与 `TaskRow` 对齐，省掉一层映射。 */
export interface NewTask {
  title: string;
  cpl_time: string;
  loop_id?: string | null;
  description?: string | null;
  is_word?: boolean;
  recurrence?: Recurrence;
  reward_points?: number;
  priority?: Priority;
  created_at?: string;
}

/** `addTask` 的返回：`id` 为 `null` 表示**因重复被静默跳过**（spec §2.8）。 */
export interface AddTaskResult {
  id: number | null;
  /** 实际使用的 `loop_id`（新建循环任务时新生成的那个）。 */
  loop_id: string | null;
  /** 命中重复而跳过时为 `true`——UI 不弹提示，但调用方可用它跳过打标签。 */
  skippedAsDuplicate: boolean;
}

// ── 1. 查询 ───────────────────────────────────────────────────────────────

/** 首页/日历主查询（spec §2.1）：当天全部任务，**无 LIMIT**，五键排序。 */
export function getTasksForDate(date: Date = new Date()): TaskRow[] {
  const { start, end } = dayRange(date);
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks
      WHERE cpl_time >= ? AND cpl_time < ?
      ORDER BY ${ORDER_BY_FOR_DATE}`,
    [start, end],
    '查询指定日期的任务',
  );
}

/** 按 id 批量取任务（任务列表用）。保留传入顺序，不做排序。 */
export function getTasksByIds(ids: readonly number[]): TaskRow[] {
  if (ids.length === 0) return [];
  const placeholders = ids.map(() => '?').join(', ');
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks WHERE id IN (${placeholders})`,
    [...ids],
    '按 id 批量查询任务',
  );
}

export interface SearchOptions {
  /** 命中重复时静默跳过。 */
  limit?: number;
  offset?: number;
}

/**
 * 菜单面板搜索 / 高级搜索（spec §2.2）。
 *
 * ⚠️ `limit` 默认 **50**，UI 永不传别的值、也不分页（`offset` 恒为 0）。
 */
export function searchTasks(
  query: string,
  options: {
    startDate?: Date | null;
    endDate?: Date | null;
    completionStatus?: boolean | null;
  } = {},
  paging: SearchOptions = {},
): TaskRow[] {
  const { sql: where, params } = buildSearchWhere({ query, ...options });
  const limit = paging.limit ?? 50;
  const offset = paging.offset ?? 0;
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks${where}
      ORDER BY ${ORDER_BY_WITH_ID_TIEBREAKER}
      LIMIT ? OFFSET ?`,
    [...params, limit, offset],
    '搜索任务',
  );
}

/** 月视图 / 统计（spec §2.3）：`[start, end)` 区间，按 `cpl_time DESC`。 */
export function getTasksByDateRange(start: Date, end: Date): TaskRow[] {
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks
      WHERE cpl_time >= ? AND cpl_time < ?
      ORDER BY ${ORDER_BY_RANGE_WITH_ID_TIEBREAKER}`,
    [isoMinute(start), isoMinute(end)],
    '查询日期范围内的任务',
  );
}

/** 全部循环任务（spec §2.4）：**无 ORDER BY、无 LIMIT、无去重**。 */
export function getRecurringTasks(): TaskRow[] {
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks WHERE recurrence != 'none'`,
    [],
    '查询循环任务',
  );
}

/** 指定 loop 的全部实例（spec §2.5）：**无 ORDER BY**，含过去的实例。 */
export function getTasksByLoopId(loopId: string): TaskRow[] {
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks WHERE loop_id = ?`,
    [loopId],
    '查询循环系列的任务',
  );
}

/** 按 id 取单条（不存在返回 `undefined`）。 */
export function getTaskById(id: number): TaskRow | undefined {
  return queryOne<TaskRow>(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?`, [id], '查询任务');
}

/**
 * 数据导出用：全量任务，`cpl_time DESC`，**无 LIMIT**。
 *
 * ⚠️ 名字带 `ForExport` 是刻意的——Flutter 侧 `TaskRepository` **刻意不暴露**
 * `getAllTasks()`（见 `task_repository.dart:15` 的注释），全量扫描只服务于
 * 数据导出这一个场景。用后缀表达同一意图，避免有人当成「列表查询」来用。
 */
export function getAllTasksForExport(): TaskRow[] {
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks ORDER BY cpl_time DESC, id DESC`,
    [],
    '导出任务',
  );
}

/** 某条 loop 是否已在指定当天存在实例（去重键 = `loop_id` + 当天，spec §4.5）。 */
export function existsInLoopOnDate(loopId: string, date: Date): boolean {
  const { start, end } = dayRange(date);
  const row = queryOne<{ id: number }>(
    SQL_EXISTS_IN_LOOP,
    [loopId, start, end],
    '检查循环实例是否重复',
  );
  return row !== undefined;
}

// ── 2. 创建（含双分支重复检测） ────────────────────────────────────────────

/**
 * 新增任务（spec §2.8 + §3.1）。
 *
 * 流程：`recurrence != 'none' && loop_id == null` 时先生成 `loop_id`
 * → 按分支做重复检测 → 未重复才 INSERT。
 *
 * ⚠️ **命中重复时静默跳过**，`id` 为 `null`、**不抛错不提示**——
 * 这是既有行为（1:1 复刻，不要"修好它"）。调用方靠 `id == null`
 * 跳过后续的打标签步骤（见 spec §3.1 入口 1）。
 */
export function addTask(input: NewTask): AddTaskResult {
  const recurrence = input.recurrence ?? 'none';
  let loopId = input.loop_id ?? null;
  if (recurrence !== 'none' && loopId === null) {
    loopId = generateLoopId();
  }

  const cplTime = input.cpl_time;
  const day = dayRange(new Date(cplTime.replace(' ', 'T')));

  const duplicate = existsDuplicate(input.title, input.description ?? null, loopId, recurrence, day);
  if (duplicate) {
    return { id: null, loop_id: loopId, skippedAsDuplicate: true };
  }

  const now = nowLocalIso();
  const id = insertTaskRow({
    loop_id: loopId,
    title: input.title,
    description: input.description ?? null,
    is_word: fromBool(input.is_word ?? false),
    is_ok: fromBool(false),
    cpl_time: cplTime,
    recurrence,
    completed_at: null,
    reward_points: input.reward_points ?? 0,
    is_deducted: fromBool(false),
    created_at: input.created_at ?? now,
    priority: input.priority ?? 'white',
  });
  return { id, loop_id: loopId, skippedAsDuplicate: false };
}

/** 重复检测的分支判定 + 存在性查询。 */
export function existsDuplicate(
  title: string,
  description: string | null,
  loopId: string | null,
  recurrence: Recurrence,
  day: { start: string; end: string },
): boolean {
  if (duplicateBranch(recurrence, loopId) === 'loop') {
    const row = queryOne<{ id: number }>(SQL_EXISTS_IN_LOOP, [loopId, day.start, day.end], '检查循环重复');
    return row !== undefined;
  }
  const row = queryOne<{ id: number }>(
    existsOnDateSql(description),
    existsOnDateParams(title, description, day),
    '检查任务重复',
  );
  return row !== undefined;
}

/** 插入一行任务，返回自增 id。**不含 id 列**，让 SQLite 分配。 */
function insertTaskRow(row: Omit<TaskRow, 'id'>): number {
  const handle = db();
  const res = handle.executeSync(
    `INSERT INTO tasks
       (loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
        completed_at, reward_points, is_deducted, created_at, priority)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      row.loop_id,
      row.title,
      row.description,
      fromBool(Boolean(row.is_word)),
      fromBool(Boolean(row.is_ok)),
      row.cpl_time,
      row.recurrence,
      row.completed_at,
      row.reward_points,
      fromBool(Boolean(row.is_deducted)),
      row.created_at,
      row.priority,
    ] as never,
  );
  return res.insertId ?? 0;
}

// ── 3. 完成 / 取消完成 ────────────────────────────────────────────────────

/** 结算流水的两种 type（`core/points.ts` 的 `SettlementType`）。 */
const SETTLEMENT_TYPES = ['task_complete', 'task_uncomplete'] as const;

/**
 * 完成任务（spec §3.2）。
 *
 * 写入 `is_ok = 1` + `completed_at = now`，再按幂等规则结算积分。
 *
 * ⚠️ `completed_at` 写的是**真实时刻**，不是任务的 `cpl_time`——
 * 补做昨天的任务时，`completed_at` 是今天。
 * ⚠️ **完成时不生成循环实例**（生成只发生在创建 / 编辑 / 冷启动，spec §4.1）。
 *
 * @returns 实际入账的积分（0 表示未加分：reward 为 0、或已加过）
 */
export async function completeTask(taskId: number): Promise<number> {
  const now = nowLocalIso();
  await writeBatch([['UPDATE tasks SET is_ok = 1, completed_at = ? WHERE id = ?', [now, taskId]]], '完成任务');

  const task = getTaskById(taskId);
  if (!task) return 0;

  const latest = getLatestPointsRecord(taskId, SETTLEMENT_TYPES);
  const decision = resolveCompletion({
    rewardPoints: task.reward_points,
    latestSettlementType: (latest?.type as SettlementType) ?? null,
  });
  if (decision.action !== 'award') return 0;

  await applyTaskSettlement({
    delta: decision.points,
    type: 'task_complete',
    description: `完成任务: ${task.title}`,
    relatedId: taskId,
  });
  return decision.points;
}

/**
 * 取消完成（spec §3.3）——**本模块最容易写错的地方**。
 *
 * 扣减金额取**最近那条 `task_complete` 流水的 `points`**，不是任务当前的
 * `reward_points`：完成期间改过奖励值也要对称冲销。
 *
 * @returns 实际扣回的积分（0 表示无需冲销）
 */
export async function uncompleteTask(taskId: number): Promise<number> {
  await writeBatch(
    [['UPDATE tasks SET is_ok = 0, completed_at = NULL WHERE id = ?', [taskId]]],
    '取消完成',
  );

  const task = getTaskById(taskId);
  if (!task) return 0;

  const latest = getLatestPointsRecord(taskId, SETTLEMENT_TYPES);
  const decision = resolveUncompletion({
    latestSettlementType: (latest?.type as SettlementType) ?? null,
    latestSettlementPoints: latest?.points ?? null,
  });
  if (decision.action !== 'reverse') return 0;

  await applyTaskSettlement({
    delta: -decision.points,
    type: 'task_uncomplete',
    description: `取消完成: ${task.title}`,
    relatedId: taskId,
  });
  return decision.points;
}

/**
 * 余额变更 + 写流水，**同一事务**（余额与流水的不变量前提，schema-v3 §7 第 2 条）。
 *
 * ⚠️ **不校验余额**（不传 `requireAtLeast`）——照搬 Flutter。
 * 逾期扣分允许把余额扣成负数；若这里无脑加 `points >= 0`，
 * 余额已经是 -5 时 UPDATE 命中 0 行 → 扣分被静默跳过，而调用方还会
 * 置 `is_deducted = 1` → 该任务永久漏扣。
 */
async function applyTaskSettlement(s: {
  delta: number;
  type: 'task_complete' | 'task_uncomplete' | 'overdue_deduct';
  description: string;
  relatedId: number;
}): Promise<void> {
  const now = nowLocalIso();
  await runTransaction(
    async (tx) => {
      await exec(
        tx,
        'UPDATE user_points SET points = points + ?, updated_at = ? WHERE id = ?',
        [s.delta, now, 1],
      );
      await insertRecord(tx, {
        points: s.delta,
        type: s.type,
        description: s.description,
        relatedId: s.relatedId,
      });
    },
    '结算任务积分',
  );
}

// ── 4. 编辑（含 updateAll 六字段联动） ─────────────────────────────────────

/** 编辑入参：`id` 必填，其余为要写入的列。 */
export interface EditTaskInput {
  id: number;
  title: string;
  cpl_time: string;
  loop_id?: string | null;
  description?: string | null;
  is_word?: boolean;
  is_ok?: boolean;
  recurrence?: Recurrence;
  completed_at?: string | null;
  reward_points?: number;
  is_deducted?: boolean;
  created_at?: string;
  priority?: Priority;
}

/**
 * 编辑任务（spec §3.4）。
 *
 * 单条更新是**全列覆盖**（Flutter 的 `db.update(task.toMap())` 不含 id，
 * 其余 12 列全写）。联动更新只写**6 个字段**：`title / description /
 * is_word / reward_points / priority / recurrence`——**不含 `cpl_time`**，
 * 所以「全部更新」不会移动其他实例的日期。
 *
 * ⚠️ 联动是**逐条 UPDATE 且不在事务里**（照搬 Flutter），中途失败会部分更新。
 *
 * @param updateAll 为 true 时，同 loop 中**不早于本任务**的实例一起改这 6 个字段
 * @returns 被联动修改的实例数（不含本条）
 */
export async function updateTask(input: EditTaskInput, updateAll = false): Promise<number> {
  const row: TaskRow = {
    id: input.id,
    loop_id: input.loop_id ?? null,
    title: input.title,
    description: input.description ?? null,
    is_word: fromBool(input.is_word ?? false),
    is_ok: fromBool(input.is_ok ?? false),
    cpl_time: input.cpl_time,
    recurrence: input.recurrence ?? 'none',
    completed_at: input.completed_at ?? null,
    reward_points: input.reward_points ?? 0,
    is_deducted: fromBool(input.is_deducted ?? false),
    created_at: input.created_at ?? nowLocalIso(),
    priority: input.priority ?? 'white',
  };

  await updateTaskRow(row);

  if (!updateAll) return 0;
  if (row.recurrence === 'none' || row.loop_id === null) return 0;
  return propagateToLoop(row);
}

/** 单条全列覆盖更新。 */
async function updateTaskRow(row: TaskRow): Promise<void> {
  await writeBatch(
    [
      [
        `UPDATE tasks SET
            loop_id = ?, title = ?, description = ?, is_word = ?, is_ok = ?,
            cpl_time = ?, recurrence = ?, completed_at = ?, reward_points = ?,
            is_deducted = ?, created_at = ?, priority = ?
          WHERE id = ?`,
        [
          row.loop_id,
          row.title,
          row.description,
          row.is_word,
          row.is_ok,
          row.cpl_time,
          row.recurrence,
          row.completed_at,
          row.reward_points,
          row.is_deducted,
          row.created_at,
          row.priority,
          row.id,
        ],
      ],
    ],
    '更新任务',
  );
}

/** 把 6 个联动字段刷到同 loop 的「不早于本任务」的实例上。 */
async function propagateToLoop(source: TaskRow): Promise<number> {
  const siblings = getTasksByLoopId(source.loop_id as string);
  const targets = siblings.filter(
    (t) => shouldPropagate(t.cpl_time, source.cpl_time, t.id === source.id),
  );
  for (const t of targets) {
    // ⚠️ 只写 6 列：cpl_time / completed_at / is_ok / is_deducted / created_at
    // 保持各实例自己的值（spec §3.4）。
    await writeBatch(
      [
        [
          `UPDATE tasks SET title = ?, description = ?, is_word = ?,
                           reward_points = ?, priority = ?, recurrence = ?
            WHERE id = ?`,
          [
            source.title,
            source.description,
            source.is_word,
            source.reward_points,
            source.priority,
            source.recurrence,
            t.id,
          ],
        ],
      ],
      '联动更新循环任务',
    );
  }
  return targets.length;
}

// ── 5. 删除 ───────────────────────────────────────────────────────────────

/**
 * 删除任务（spec §3.6）。
 *
 * - `deleteAll: false`（默认）→ **移入回收站**。实现委托给 `recycleRepo`，
 *   不在这里重复实现（它已带 V6 三步守卫）。
 * - `deleteAll: true` → **物理删除整个 loop 的未来实例，不经回收站**。
 *   这是 V1 补充才发现的第四条路径，`recycleRepo` 没有，归本文件。
 *
 * @returns 实际删除的实例数（`deleteAll:false` 返回 0 或 1）
 */
export async function deleteTask(taskId: number, deleteAll = false): Promise<number> {
  if (!deleteAll) {
    const failure = await moveTaskToRecycleBin(taskId);
    if (failure !== null) throw new Error(failure);
    return 1;
  }
  return deleteRecurringInstances(taskId);
}

/**
 * 批量物理删除循环任务（`deleteAll: true`）。
 *
 * ⚠️ **不进回收站、不可恢复。** 保留「不早于本任务」的实例，过去的不删。
 *
 * ⚠️ **M1 引入事务**（V1 补充的原子性修复）：Flutter 侧是循环
 * `await db.delete(...)`、**不在事务里**，中途失败会留下「删了一半」的循环链。
 *
 * 🔴 **V6 三步**（与 `m1-decisions.md` V6 一致，编号相同）：
 * 1. 清理条件用 **`task_id`**——本路径的 `task_id` 就是任务 id 本身
 *    （不经回收站，所以没有 `recycled_tasks.task_id` 映射问题）；
 * 2. **只删本次真正被物理删除的那几行**，不是整个 loop 的全部实例
 *    （过去的不该被清，它们还挂在活着的任务上）；
 * 3. 附带 `NOT IN (SELECT id FROM tasks)` 守卫，确保不会删掉仍活着的任务的关联。
 *
 * 第 3 步最隐蔽：前两步写对、逻辑完全正确，**照样能删掉活任务的标签**——
 * 而此时 `tasks` 里那些实例已被同事务删除，守卫才拦得住「顺序」之外的情况。
 *
 * ⚠️ **「被裁剪的条目」≠「其任务已永久删除」**：金样本里 `recycled_tasks.id=1`
 * 与 `task_id=5` 并存，而 `tasks` 里 **id=5 是活着的**——此时守卫**挡下清理是正确行为**，
 * 因为那条关联挂在活任务 5 上，清掉才是数据损失。守卫挡下 ≠ 守卫出错。
 */
export async function deleteRecurringInstances(taskId: number): Promise<number> {
  const source = getTaskById(taskId);
  if (!source) return 0;
  if (source.recurrence === 'none' || source.loop_id === null) return 0;

  const siblings = getTasksByLoopId(source.loop_id);
  const targets = siblings.filter((t) => shouldPropagate(t.cpl_time, source.cpl_time, false));
  if (targets.length === 0) return 0;

  const ids = targets.map((t) => t.id);

  return runTransaction(
    async (tx) => {
      // 🔴 **顺序：先删 `tasks`，再清 `task_tags`**——与回收站三处**相反**。
      //
      // **前提**（缺了它，下一个人会以为回收站三处的顺序也该改成「先删 tasks」）：
      // - 回收站三处：条目在**移入回收站时**任务就已经从 `tasks` 移走了，
      //   所以清关联时守卫**必然放行**（任务确实已经不在 `tasks` 里了）；
      // - **本路径**：这批任务是**本次事务才要删**的，此刻还在 `tasks` 里，
      //   所以必须**先删 `tasks`**、守卫才放行。
      //
      // 为什么不能「统一」成同一个顺序（这是本文件最容易踩的坑）：
      //
      // | 路径 | 任务此刻在 `tasks` 里吗 | 正确顺序 |
      // |---|---|---|
      // | 回收站三处（裁剪/单条永久删除/清空） | **不在**（移入回收站时已移走） | 先清 `task_tags` → 再删 `recycled_tasks` |
      // | **本路径（deleteAll 批量删循环任务）** | **在**（本次事务才删它） | **先删 `tasks` → 再清 `task_tags`** |
      //
      // 根因：`NOT IN (SELECT id FROM tasks)` 这个守卫的语义是
      // 「**只清已经不在 `tasks` 里的**任务的关联」。本路径里任务此刻还在，
      // 所以**若先清，守卫会把它挡掉 → 清理从未执行 → 随后任务被删 → 关联成孤儿**。
      // 换言之：**统一的是守卫，不是顺序。**
      for (const id of ids) {
        await exec(tx, 'DELETE FROM tasks WHERE id = ?', [id]);
      }
      // 任务已删 → 守卫此时放行 → 清理真正生效。
      // ⚠️ 用**共用函数**而不是就地写 SQL：V6 第 3 步守卫只有这一份实现，
      // 将来改一处忘一处就会静默删掉活任务的标签（V6 的教训）。
      await deleteTaskTagsForDeletedTasks(tx, ids);
      return ids.length;
    },
    '批量删除循环任务',
  );
}

// ── 6. 逾期判定与扣分 ─────────────────────────────────────────────────────

/**
 * 逾期候选集（spec §2.7 / §3.5）——**四个条件缺一不可**：
 *
 * ```
 * cpl_time < 当天 00:00   ← 不是 now！今天到期不算逾期（T4）
 * AND is_ok = 0
 * AND is_deducted = 0
 * AND recurrence = 'none' ← 循环任务永不逾期扣分
 * ```
 */
export function getOverdueTasks(now: Date = new Date()): TaskRow[] {
  return queryAll<TaskRow>(
    `SELECT ${TASK_COLUMNS} FROM tasks
      WHERE cpl_time < ? AND is_ok = 0 AND is_deducted = 0 AND recurrence = 'none'`,
    [overdueUpperBound(now)],
    '查询逾期任务',
  );
}

/**
 * 逾期扣分的幂等标记：**补扣**语义（spec §3.5）。
 *
 * ⚠️ 名字从 Flutter 的 `markTaskDeducted` 改成 `catchUpOverdueDeduction`
 * （P1-4 裁决）：原名与行为相反——它不是「打标记」，而是把之前因各种原因
 * 没扣成的 `floor(rewardPoints/2)` 真正扣掉。**纯重命名、零行为变化。**
 */
export async function catchUpOverdueDeduction(taskId: number): Promise<number> {
  await writeBatch(
    [['UPDATE tasks SET is_deducted = 1 WHERE id = ?', [taskId]]],
    '标记逾期已扣分',
  );
  return 1;
}

/**
 * 冷启动时跑的逾期检查（spec §3.5）。
 *
 * ⚠️ **无定时器**——只在应用冷启动首页时跑一次，跨午夜不会触发。
 *
 * 🔴 **顺序红线**：先扣分、再置 `is_deducted`。反过来一旦扣分失败，
 * 任务会被**永久漏扣**（标记已置位，不再进入候选集）。
 *
 * ⚠️ `catchUpOverdueDeduction` 在 `if` **之外无条件执行**——
 * 即使扣 0 分（`rewardPoints === 1` → `floor(0.5) === 0`）或已有流水，
 * 标记仍会被置 1。既有行为，照抄。
 *
 * @returns 实际扣分的任务数
 */
export async function checkOverdueTasks(now: Date = new Date()): Promise<number> {
  const candidates = getOverdueTasks(now);
  let deducted = 0;

  for (const task of candidates) {
    // 二次防御（SQL 已过滤，这里对齐 Flutter 的防御性判断）。
    if (task.is_ok !== 0 || task.is_deducted !== 0) continue;
    if (task.reward_points <= 0) continue;

    // 门 2：流水级查重（门 1 已在 SQL 的 is_deducted = 0 里）。
    const hasRecord = queryScalar(
      'SELECT COUNT(*) FROM points_records WHERE type = ? AND related_id = ?',
      ['overdue_deduct', task.id],
      '查询逾期扣分流水',
    );
    // 上面的 guard 已确保 `is_ok === 0` 且 `is_deducted === 0`，所以这里恒为 false。
    // 仍然显式传，因为 `resolveOverdueDeduction` 是独立的纯函数、不该依赖调用方的收窄。
    const decision = resolveOverdueDeduction({
      isOK: false,
      isDeducted: false,
      rewardPoints: task.reward_points,
      hasOverdueRecord: hasRecord > 0,
    });
    if (decision.action === 'deduct') {
      await applyTaskSettlement({
        delta: -decision.points,
        type: 'overdue_deduct',
        description: `逾期任务扣除: ${task.title}`,
        relatedId: task.id,
      });
      deducted += 1;
    }

    // 🔴 无条件置位——即使上面没扣成钱。
    await catchUpOverdueDeduction(task.id);
  }
  return deducted;
}

// ── 7. 循环实例生成 ───────────────────────────────────────────────────────

/** 一条循环实例的落库结果统计。 */
export interface GenerateResult {
  /** 候选日期数（`generateInstanceDates` 产出）。 */
  candidates: number;
  /** 实际插入的实例数（已扣掉同日重复的）。 */
  inserted: number;
}

/**
 * 生成循环实例（spec §4）。
 *
 * ⚠️ 四条必须照搬的语义：
 * 1. **去重键是 `loop_id` + 当天**，不是 title；
 * 2. **窗口上界 `now + 15 天`、起点是模板当天 00:00、无下界**
 *    （模板很旧会从旧日期逐日回补，属既有行为）；
 * 3. **新实例不带标签**——只 INSERT `tasks`，从不写 `task_tags`；
 * 4. **`created_at` 复制模板**，不是生成时刻。
 *
 * ⚠️ **循环实例固定 `is_deducted = 0`**。
 * 「模板已扣分时，是否对已生成的实例补扣」是**未定义行为**，
 * M1 **照搬 Flutter 现状（不补扣）**，留待 v6.x 决策。
 *
 * ⚠️ `loop_id` 为 null 时**直接返回、什么都不生成**——这是照搬：
 * Flutter 侧的历史循环任务（`loopId == null`）在生成器里被首行挡掉，
 * 所以 `autoCheckRecurringTasks` 的「复合键归并」对它们其实是无效功。
 */
export async function generateRecurringTasks(template: TaskRow, now: Date = new Date()): Promise<GenerateResult> {
  if (!template.loop_id) return { candidates: 0, inserted: 0 };
  if (template.recurrence === 'none') return { candidates: 0, inserted: 0 };

  const cplTime = new Date(template.cpl_time.replace(' ', 'T'));
  const dates = generateInstanceDates(template.recurrence as CoreRecurrence, cplTime, now);

  // 一次查出该 loop 已存在的所有日期 → Set，避免逐日查库。
  const existing = new Set<string>();
  const range = dayRange(now);
  const rows = queryAll<{ cpl_time: string }>(
    `SELECT cpl_time FROM tasks
      WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ?`,
    [template.loop_id, range.start, range.end],
    '查询已存在的循环实例',
  );
  for (const r of rows) existing.add(dayKey(r.cpl_time));

  const toInsert: TaskRow[] = [];
  const seen = new Set<string>();
  for (const date of dates) {
    const key = instanceKey(template.loop_id, date);
    if (seen.has(key)) continue; // 同一次生成里的重复（理论上不会发生，防呆）
    seen.add(key);
    if (existing.has(dayKey(localDate(date)))) continue; // 去重键：loop + 当天
    toInsert.push({
      id: 0, // 占位，insertTaskRow 不含 id 列
      loop_id: template.loop_id,
      title: template.title,
      description: template.description,
      is_word: template.is_word,
      is_ok: fromBool(false), // 固定未完成
      cpl_time: isoMinute(date),
      recurrence: template.recurrence,
      completed_at: null, // 固定未完成
      reward_points: template.reward_points,
      is_deducted: fromBool(false), // 固定未扣（见上方警告）
      created_at: template.created_at, // 复制模板
      priority: template.priority,
    });
  }

  if (toInsert.length === 0) return { candidates: dates.length, inserted: 0 };

  // 单事务批量插入：任一条失败则整体回滚，避免「插了一半的循环链」。
  await runTransaction(
    async (tx) => {
      for (const row of toInsert) {
        await exec(
          tx,
          `INSERT INTO tasks
             (loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
              completed_at, reward_points, is_deducted, created_at, priority)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            row.loop_id,
            row.title,
            row.description,
            row.is_word,
            row.is_ok,
            row.cpl_time,
            row.recurrence,
            row.completed_at,
            row.reward_points,
            row.is_deducted,
            row.created_at,
            row.priority,
          ],
        );
      }
    },
    '生成循环任务实例',
  );

  return { candidates: dates.length, inserted: toInsert.length };
}

/**
 * 冷启动时的循环实例补全（spec §4.2）。
 *
 * 取每个 `loop_id` 中 **`cpl_time` 最早**的一条作模板。
 * `loop_id` 为空的历史任务用复合键
 * `title||description||recurrence||isWord||rewardPoints` 归并——
 * 但这些行在 `generateRecurringTasks` 首行就被挡掉，**归并对它们无效**（照搬）。
 */
export async function autoCheckRecurringTasks(now: Date = new Date()): Promise<GenerateResult> {
  const recurring = getRecurringTasks();
  if (recurring.length === 0) return { candidates: 0, inserted: 0 };

  const templates = new Map<string, TaskRow>();
  for (const task of recurring) {
    const key =
      task.loop_id ??
      `${task.title}||${task.description}||${task.recurrence}||${task.is_word}||${task.reward_points}`;
    const kept = templates.get(key);
    if (!kept || kept.cpl_time > task.cpl_time) templates.set(key, task);
  }

  let candidates = 0;
  let inserted = 0;
  for (const template of templates.values()) {
    const r = await generateRecurringTasks(template, now);
    candidates += r.candidates;
    inserted += r.inserted;
  }
  return { candidates, inserted };
}

// ── 8. 回收站读写（实现委托给 recycleRepo，本文件只做再导出） ──────────────

/**
 * ⚠️ **刻意不在本文件实现**——`recycleRepo.ts` 已有同一份实现且已带 V6 守卫。
 * 重复实现会让「某个永久删除路径忘了加 `NOT IN (SELECT id FROM tasks)`」
 * 这类缺陷获得第二个温床（通则 6 第 5 条）。
 *
 * 另见文件头「与 recycleRepo.ts 的分工」说明。
 *
 * ⚠️ `permanentDelete` 在本文件导出名是 `deleteFromRecycle`（与 Flutter 侧同名），
 * 而 recycleRepo 里叫 `permanentDelete`——别名在这里转一次，调用方不必知道。
 */
export {
  getRecycledTasks,
  clearRecycleBin,
  restoreTaskFromRecycle,
  restoreSingleInstance,
  permanentDelete as deleteFromRecycle,
  RECYCLE_BIN_LIMIT,
  type RestoreResult,
} from './recycleRepo';
