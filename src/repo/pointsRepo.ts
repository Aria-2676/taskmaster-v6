/**
 * 积分仓储：余额读写 + 流水写入 + 幂等查询 + 明细列表。
 *
 * 对应 Flutter 侧 `database_points_mixin.dart` + `points_provider.dart`，
 * 规格见 docs/migration/spec-points-shop.md A 章。
 *
 * ── 三条必须守住的规则 ─────────────────────────────────────────────────
 *
 * 1. **余额变更一律用 `UPDATE ... SET points = points ± ?`**，绝不「读出来在 JS 里
 *    算好再写回」——后者在并发下会丢失更新（spec A.2 / F2）。
 * 2. **余额校验下推到 SQL**：`WHERE points >= ?`，靠 `rowsAffected > 0` 判成败，
 *    不先 SELECT 再判断（避免读-改-写竞态，spec A.2 / F3）。
 * 3. **`overdue_deduct` 不传余额校验（允许负余额），`shop_purchase` / `scratch_cost`
 *    传**——同一套 API 两种语义（spec A.7 / F4）。
 *
 * 关于「为什么余额校验要用 `tx.ts` 的事务而不是 `base.ts` 的 `writeBatch`」，
 * 见 `tx.ts` 顶部注释——`executeBatch` 拿不到逐条 `rowsAffected`，
 * 混用两条执行路径会破坏 `balance == SUM(流水)` 不变量。
 *
 * 结算口径（该不该加、该加多少）由 `core/points.ts` 的纯函数决定，
 * 本文件只负责「把算好的金额落库」。
 */

import { queryOne, queryAll, queryScalar, writeBatch, nowLocalIso, db, toRepoError } from './base';
import {
  exec,
  execInsert,
  runTransaction,
  ensureUserPointsRow,
  balanceUpdateSql,
  balanceUpdateParams,
  InsufficientPointsError,
  type Tx,
} from './tx';
import type { PointsRecordRow, UserPointsRow } from './types';
import { POINTS_RECORD_LIMIT } from '../core/pointsRules';

/** 写流水时的入参。`description` 对应 DDL 的 `NOT NULL` 列，不能省。 */
export interface PointsRecordInput {
  /** **带符号**：收入为正、支出为负。调用方负责符号，这里不取绝对值。 */
  points: number;
  /** 7 种之一（见 `core/pointsRules.ts` 的 `PointsRecordType`）。 */
  type: string;
  /** 展示文案，如 `完成任务: <title>`。 */
  description: string;
  /** 关联 id；语义随 `type` 变化（见 `PointsRecordRow.related_id`）。 */
  relatedId?: number | null;
}

/** 单行表 `user_points` 的固定主键。 */
const USER_POINTS_ID = 1;

/** 结算幂等查询用的两种流水类型（`task_settlement_mixin.dart` 的 `_taskSettlementTypes`）。 */
const SETTLEMENT_TYPES: readonly string[] = ['task_complete', 'task_uncomplete'];

/** 插入一条流水的 SQL。抽出常量以便复用（本文件内 3 处要用）。 */
const INSERT_RECORD_SQL =
  'INSERT INTO points_records (points, type, description, related_id, created_at) VALUES (?, ?, ?, ?, ?)';

/* ── 余额 ─────────────────────────────────────────────────────────────── */

/**
 * 懒初始化并读取余额。
 *
 * 查不到行时插入一行 `points = 0` 再返回——对应 `getUserPoints()`。这是唯一的
 * 建行入口，所有写积分的方法都先调它保证行存在。
 *
 * 注：`user_points` **没有** `CHECK (id = 1)`（`pomodoro_settings` 才有，spec G3），
 * 单行性纯靠代码约定，因此这里恒用 `id = 1` 读写，不依赖库自己去重。
 */
export function getUserPoints(): UserPointsRow {
  const existing = queryOne<UserPointsRow>(
    'SELECT id, points, updated_at FROM user_points WHERE id = ? LIMIT 1',
    [USER_POINTS_ID],
    '读取积分余额',
  );
  if (existing) return existing;

  ensureUserPointsRow();
  return { id: USER_POINTS_ID, points: 0, updated_at: nowLocalIso() };
}

/** 只取余额数值。 */
export function getBalance(): number {
  return getUserPoints().points;
}

/** 余额与流水净额是否一致——`balance == SUM(流水)` 是不变量（schema-v3 §7 第 2 条）。 */
export function checkBalanceInvariant(): {
  balance: number;
  ledgerSum: number;
  consistent: boolean;
} {
  const balance = getBalance();
  const ledgerSum = queryScalar(
    'SELECT COALESCE(SUM(points), 0) FROM points_records',
    [],
    '汇总积分流水',
    0,
  );
  return { balance, ledgerSum, consistent: balance === ledgerSum };
}

/**
 * 以原子 SQL 增减积分（**只改余额，不写流水**）。
 *
 * @param delta   增量；正为加、负为扣
 * @param requireAtLeast
 *   `undefined` / `null` → **不校验余额，允许扣成负数**（逾期扣分走这条）；
 *   数字 → 追加 `WHERE points >= requireAtLeast`，余额不足则**不改任何东西**
 *          并返回 `false`（商城兑换 / 刮刮乐购票走这条）。
 *
 * @returns 余额是否真的被改动
 */
export function applyPointsDelta(delta: number, requireAtLeast?: number | null): boolean {
  // 先确保行存在，否则 UPDATE 会命中 0 行而误报「余额不足」。
  ensureUserPointsRow();
  try {
    const res = db().executeSync(
      balanceUpdateSql(requireAtLeast),
      balanceUpdateParams(delta, requireAtLeast) as never,
    );
    return res.rowsAffected > 0;
  } catch (e) {
    throw toRepoError(e, '更新积分余额');
  }
}

/** 原子加积分（不写流水）。 */
export function addPoints(points: number): void {
  applyPointsDelta(Math.abs(points));
}

/** 原子扣积分（不写流水，**不校验余额**，允许负数——照搬 `deductPoints`）。 */
export function deductPoints(points: number): void {
  applyPointsDelta(-Math.abs(points));
}

/**
 * 覆盖写余额。
 *
 * ⚠️ **无任何 UI 入口**（spec A.9）：Flutter 侧 `updatePoints()` /
 * `PointsRepository.setPoints()` 都存在但没人调，用户**无法**手动改积分。
 * 保留是因为它是 `balance == SUM(流水)` 这条不变量的唯一破坏口，留着便于将来
 * 做「导入/重置」功能时显式调用，并在此标注不要随手接 UI。
 */
export function updateUserPoints(points: number): Promise<void> {
  ensureUserPointsRow();
  return writeBatch(
    [
      [
        'UPDATE user_points SET points = ?, updated_at = ? WHERE id = ?',
        [points, nowLocalIso(), USER_POINTS_ID],
      ],
    ],
    '覆盖写积分余额',
  );
}

/* ── 幂等查询 ─────────────────────────────────────────────────────────── */

/**
 * 查询「这个 `type` + `related_id` 有没有出现过」——逾期扣分的幂等判据。
 *
 * ⚠️ `points_records` **没有** `UNIQUE(type, related_id)`，只有**非唯一**索引
 * `idx_points_records_type_related`。所以幂等**完全靠应用层先查后写**，
 * 两个并发写可以穿透——这是**已知的弱幂等**，照搬以保持行为一致（spec A.4）。
 * 真正的强幂等靠「先置 `is_deducted` 再扣分」那层顺序保护兜底。
 */
export function hasPointsRecord(type: string, relatedId: number): boolean {
  const row = queryOne<{ c: number }>(
    'SELECT 1 AS c FROM points_records WHERE type = ? AND related_id = ? LIMIT 1',
    [type, relatedId],
    '查询积分流水',
  );
  return row !== undefined;
}

/**
 * 取某个关联对象上、指定类型集合中**最后写入**的一条流水。
 *
 * ⚠️ **按自增主键 `id` 倒序，不按时间戳**——不受时间戳精度影响（spec A.4 / F9）。
 * 时间排序在同毫秒写入时会失效，主键则严格反映写入顺序。
 *
 * 用途：判断任务当前的结算状态（已加分 / 已冲销），即
 * `resolveCompletion` / `resolveUncompletion`（`core/points.ts`）的入参来源。
 */
export function getLatestPointsRecord(
  relatedId: number,
  types: readonly string[] = SETTLEMENT_TYPES,
): PointsRecordRow | undefined {
  if (types.length === 0) return undefined;
  const placeholders = types.map(() => '?').join(', ');
  return queryOne<PointsRecordRow>(
    `SELECT id, points, type, description, related_id, created_at
       FROM points_records
      WHERE related_id = ? AND type IN (${placeholders})
      ORDER BY id DESC
      LIMIT 1`,
    [relatedId, ...types],
    '查询最近积分流水',
  );
}

/* ── 流水写入 ─────────────────────────────────────────────────────────── */

/**
 * 增减余额**并**写入流水，两步在**同一个事务**内（`transaction` 而非 `writeBatch`，
 * 因为要逐条判 `rowsAffected`，原因见 `tx.ts` 顶部注释）。
 *
 * 对应 `applyPointsChange`。同事务是余额与流水不变量
 * （`balance == SUM(流水)`）的前提：中途失败不会留下「余额变了但没流水」的脏状态。
 *
 * @param requireAtLeast 见 `applyPointsDelta`；余额不足时抛
 *                      `InsufficientPointsError` 并**整体回滚、零写入**
 * @returns 恒为 `true`；余额不足时以抛异常表达失败（而非返回 `false`），
 *          这样上层无法「忘了检查返回值」而误判成功
 */
export async function applyPointsChange(
  delta: number,
  record: PointsRecordInput,
  requireAtLeast?: number | null,
): Promise<boolean> {
  ensureUserPointsRow();
  return runTransaction(
    async (tx: Tx) => {
      await exec(
        tx,
        balanceUpdateSql(requireAtLeast),
        balanceUpdateParams(delta, requireAtLeast),
      );
      await insertRecord(tx, record);
      return true;
    },
    '写入积分流水',
  );
}

/** 在给定事务里插一条流水（供本文件与 `shopRepo` 复用，保证同事务）。 */
export async function insertRecord(tx: Tx, record: PointsRecordInput): Promise<number> {
  return execInsert(tx, INSERT_RECORD_SQL, [
    record.points,
    record.type,
    record.description,
    record.relatedId ?? null,
    nowLocalIso(),
  ]);
}

/**
 * 加分并写流水。
 *
 * ⚠️ **不传余额校验** → 允许负余额分支不受影响，且加分方向本就无需校验。
 * 对应 Flutter 的 `addPointsWithRecord`（`applyPointsChange` 不传 `requireAtLeast`）。
 */
export function addPointsWithRecord(
  points: number,
  type: string,
  description: string,
  relatedId?: number | null,
): Promise<boolean> {
  return applyPointsChange(
    points,
    { points, type, description, relatedId },
    /* requireAtLeast= */ undefined,
  );
}

/**
 * 扣分并写流水。
 *
 * ⚠️ **不传余额校验 → 允许扣成负数**。对应 Flutter 的 `deductPointsWithRecord`：
 * 结算 mixin 从不传 `requireAtLeast`，所以**逾期扣分与任务冲销都允许负余额**
 * （spec A.7）。这里刻意不传，若误传 `0` 会让「余额已为负时逾期扣分被静默跳过」，
 * 且调用方还会把 `is_deducted` 置 1，导致该任务永久漏扣。
 *
 * 金额取 `Math.abs`：`task_uncomplete` 冲销时上游给的是**正数**金额
 * （`resolveUncompletion` 的 `points`），由这里统一带上负号落库，
 * 保证流水 `points` 永远带符号（spec A.3）。
 */
export function deductPointsWithRecord(
  points: number,
  type: string,
  description: string,
  relatedId?: number | null,
): Promise<boolean> {
  const amount = Math.abs(points);
  return applyPointsChange(
    -amount,
    { points: -amount, type, description, relatedId },
    /* requireAtLeast= */ undefined,
  );
}

/** 余额不足时把 `InsufficientPointsError` 翻译成对外的失败语义（供 UI 判定）。 */
export function isInsufficientPoints(e: unknown): boolean {
  return e instanceof InsufficientPointsError;
}

/* ── 明细列表 ─────────────────────────────────────────────────────────── */

/**
 * 取最近 N 条流水（默认 50），`created_at` 倒序。
 *
 * ⚠️ **无分页、无「加载更多」、无汇总统计**——照搬 `getPointsRecords(limit: 50)`。
 * 库里 500 条流水，用户永远只看到最新 50 条（spec A.8 / F20）。
 * 展示口径（文案 / 图标 / 正负号 / 排序）见 `core/pointsRules.ts`。
 */
export function getPointsRecords(limit: number = POINTS_RECORD_LIMIT): PointsRecordRow[] {
  return queryAll<PointsRecordRow>(
    `SELECT id, points, type, description, related_id, created_at
       FROM points_records
      ORDER BY created_at DESC
      LIMIT ?`,
    [limit],
    '读取积分流水',
  );
}

/**
 * 清空全部流水。
 *
 * ⚠️ **无任何 UI 入口**（spec A.9，`clearPointsRecords` 无调用方）。
 * 且单独清流水会**破坏** `balance == SUM(流水)` 不变量（余额不动）。
 * 保留仅为将来「重置数据」功能预留，不应随手接 UI。
 */
export function clearPointsRecords(): Promise<void> {
  return writeBatch([['DELETE FROM points_records', []]], '清空积分流水');
}