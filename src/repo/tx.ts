/**
 * 事务内的执行原语。
 *
 * ── 为什么不用 `base.ts` 的 `writeBatch` 来做「需要读 affectedRows」的写入？ ──
 *
 * `writeBatch` 走 `executeBatch`，返回的 `BatchQueryResult` **只有整批的总
 * `rowsAffected`，没有逐条结果**（见 op-sqlite `types.d.ts` 的 `BatchQueryResult`）。
 * 而本模块的核心语义恰恰依赖逐条判定：
 *
 * > 余额校验下推到 `WHERE points >= ?`，靠 `rowsAffected > 0` 判成败。
 *
 * 拿不到逐条结果，就只能先把 `UPDATE` 单独执行、再用 `writeBatch` 写流水——
 * **两条执行路径不在同一个事务里**。一旦流水写入失败，余额已经改了，
 * `balance == SUM(流水)` 这条不变量（schema-v3 §7 第 2 条）当场被破坏。
 *
 * 所以这里用 `db.transaction()` + `tx.execute()`：逐条拿得到 `rowsAffected`，
 * 且抛异常时整个事务回滚（op-sqlite 文档：*"If an error is thrown it will
 * rollback all of the changes"*）。
 *
 * ── 使用纪律 ──────────────────────────────────────────────────────────
 *
 * 1. **事务内只能用 `tx.execute`**（或本文件封的 `exec` / `execInsert`），
 *    **绝不能**混用 `executeSync` 或 `writeBatch`——混用会出现「事务提交了但
 *    部分语句没进去」。
 * 2. 需要「某条 UPDATE 命中 0 行就整笔放弃」时，**抛 `InsufficientPointsError`**
 *    触发回滚，再在外层捕获。`executeBatch` 无法优雅地中途退出，只能靠抛异常。
 * 3. 事务内**不做懒初始化**：`user_points` 的建行要在事务开始前用
 *    `ensureUserPointsRow` 完成，否则就把一次写混进了事务路径。
 */

import { db, toRepoError, nowLocalIso } from './base';
import type { Transaction } from '@op-engineering/op-sqlite';

/** 事务句柄。op-sqlite 的 `Transaction` 已导出，此处只做语义别名。 */
export type Tx = Transaction;

/**
 * 「余额不足」信号。
 *
 * 抛出它会让 `runTransaction` 回滚整笔写入；外层捕获后转成业务结果
 * （商城返回失败 / UI 弹「积分不足，无法兑换」）。
 */
export class InsufficientPointsError extends Error {
  constructor(readonly required: number) {
    super('积分不足');
    this.name = 'InsufficientPointsError';
  }
}

/** 在事务内执行一条语句，返回 `rowsAffected`。 */
export async function exec(tx: Tx, sql: string, params: readonly unknown[] = []): Promise<number> {
  const res = await tx.execute(sql, params as never);
  return res.rowsAffected;
}

/** 在事务内执行一条 INSERT，返回新行主键。 */
export async function execInsert(tx: Tx, sql: string, params: readonly unknown[] = []): Promise<number> {
  const res = await tx.execute(sql, params as never);
  return res.insertId ?? 0;
}

/**
 * 在事务内执行一条 SELECT，返回首行（无结果返回 `undefined`）。
 *
 * 用 `tx.execute` 而非 `executeSync`：在事务内走同步路径会脱离事务。
 */
export async function queryInTx<T>(
  tx: Tx,
  sql: string,
  params: readonly unknown[] = [],
): Promise<T | undefined> {
  const res = await tx.execute(sql, params as never);
  return (res.rows as T[])[0];
}

/**
 * 在事务内执行一条 SELECT，返回**全部行**。
 *
 * 为什么需要它（`queryInTx` 只给首行，不够用）：
 * 「回收站裁剪」要先把**被淘汰的那几行**连同 `task_id` 一起查出来
 * （`SELECT id, task_id ... LIMIT -1 OFFSET n`），才能同事务清掉它们的标签关联。
 * 只有首行的话，就只能就地 `as` 强转 `res.rows`——那既容易写错类型，
 * 也让「事务内取多行」这件事没有统一入口。
 *
 * 同样用 `tx.execute`（不脱离事务）。
 */
export async function queryAllInTx<T>(
  tx: Tx,
  sql: string,
  params: readonly unknown[] = [],
): Promise<T[]> {
  const res = await tx.execute(sql, params as never);
  return res.rows as unknown as T[];
}

/**
 * 跑一个事务，`fn` 抛异常则整体回滚。
 *
 * @param action 出错时的动作名，用于把原始错误翻成可展示的中文消息
 */
export async function runTransaction<T>(
  fn: (tx: Tx) => Promise<T>,
  action: string,
): Promise<T> {
  const handle = db();
  try {
    let outcome: T;
    await handle.transaction(async (tx: Tx) => {
      outcome = await fn(tx);
    });
    return outcome!;
  } catch (e) {
    // 余额不足是**预期内**的业务结果，不是系统错误：原样抛给调用方判断。
    if (e instanceof InsufficientPointsError) throw e;
    throw toRepoError(e, action);
  }
}

/**
 * 确保 `user_points` 有一行 `id = 1`。
 *
 * ⚠️ **必须在事务开始前调用**，不要放进事务里——它是懒初始化，
 * 而 `db/schema.ts` 的 `SEED_SQL` 在全新安装时已经插好了这一行，
 * 所以正常路径下这里是零写入的空操作。
 *
 * 用 `INSERT OR IGNORE` 而非裸 `INSERT`：并发冷启动时两个调用方都走懒初始化
 * 不会因主键冲突而炸（Flutter 侧靠单线程规避，这里显式兜住）。
 */
export function ensureUserPointsRow(): void {
  const handle = db();
  try {
    handle.executeSync(
      'INSERT OR IGNORE INTO user_points (id, points, updated_at) VALUES (1, 0, ?)',
      [nowLocalIso()] as never,
    );
  } catch (e) {
    throw toRepoError(e, '初始化积分余额');
  }
}

/**
 * 构造余额增减 SQL：**校验与否由 `requireAtLeast` 决定，绝不写死 `points >= 0`**。
 *
 * ⚠️ 这里有个必须避开的坑：逾期扣分**允许把余额扣成负数**（spec A.7）。
 * 如果无脑写成 `WHERE points >= 0`，那么一旦余额已经是 -5，
 * `points >= 0` 为假 → UPDATE 命中 0 行 → **逾期扣分被静默跳过**，
 * 而调用方还会以为「扣过了」把 `is_deducted` 置 1 —— 该任务从此永久漏扣。
 * 所以「不校验余额」必须真的**不写这个条件**。
 *
 * @param requireAtLeast `undefined` / `null` → 不校验（允许负余额）；
 *                        数字 → 追加 `AND points >= ?`
 */
export function balanceUpdateSql(requireAtLeast?: number | null): string {
  const checking = typeof requireAtLeast === 'number';
  return checking
    ? 'UPDATE user_points SET points = points + ?, updated_at = ? WHERE id = ? AND points >= ?'
    : 'UPDATE user_points SET points = points + ?, updated_at = ? WHERE id = ?';
}

/** 配套的 `balanceUpdateSql` 参数。顺序与 SQL 中的占位符一一对应。 */
export function balanceUpdateParams(
  delta: number,
  requireAtLeast?: number | null,
  now: string = nowLocalIso(),
): unknown[] {
  return typeof requireAtLeast === 'number'
    ? [delta, now, 1, requireAtLeast]
    : [delta, now, 1];
}