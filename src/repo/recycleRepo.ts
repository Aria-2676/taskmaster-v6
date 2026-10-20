/**
 * 回收站仓储：移入（事务内裁剪到 ≤10 条）、恢复（H1 特批）、永久删除、清空。
 *
 * 对应 Flutter 侧 `task_repository.dart` 的 `deleteTask` / `restoreTaskFromRecycle`
 * / `deleteFromRecycle` / `clearRecycleBin`，规格见 spec-points-shop.md D 章。
 *
 * ⚠️ 权威实现是 `TaskRepository`，**不是** `database_task_mixin.dart`——
 * 后者的 `moveTaskToRecycleBin` / `restoreTaskFromRecycle` 等 6 个方法
 * **全部无调用方，是死代码**，而且 `moveTaskToRecycleBin` **不写 `loop_id`**
 * （spec D.2 / F13）。照搬 `TaskRepository`：写 `loop_id`，恢复时读回，循环链不断。
 *
 * ── 保留策略（务必如实告知用户） ──────────────────────────────────────
 *
 * | 项 | 值 |
 * |---|---|
 * | 条数上限 | **10 条**（`RECYCLE_BIN_LIMIT`） |
 * | 时间过期 | **无**。不按天、不按小时清理 |
 * | 触发时机 | **只在移入新任务时**裁剪 |
 * | 裁剪对象 | `deleted_at` 倒序后的第 11 条起（**最旧的**） |
 *
 * 所以 UI 文案**不能**写「删除的任务会保留一段时间」（Flutter 版的原话，误导），
 * 应当表述为「**仅保留最近 10 条**」（spec H11 裁定，本仓储导出常量供 UI 引用，
 * 不要在 UI 里硬编码数字）。
 */

// ⚠️ 不再import `writeBatch`：三处永久删除路径改用 `runTransaction`（V1 要求清理与
// 删除同事务，且需要逐条读取 `task_id`，`writeBatch` 做不到）。
import { queryOne, queryAll, queryScalar, nowLocalIso, RepoError } from './base';
import { runTransaction, queryInTx, queryAllInTx, type Tx } from './tx';
import type { RecycledTaskRow } from './types';
import type { TaskRow } from './types';

/**
 * 回收站条数上限。**UI 层请引用这个常量，不要硬编码 10**（spec H11）。
 *
 * ⚠️ **无时间过期机制**：不是「保留 N 天」，是「只留最近 N 条」。
 * 删了 11 个任务，第 1 个**立即**被物理删除、不可恢复。
 */
export const RECYCLE_BIN_LIMIT = 10;

/** 永久删除的二次确认信息（H12）。仓储只提供数据，弹框由 UI 负责。 */
export interface ConfirmableAction {
  /** 恒为 `true`——提醒调用方**必须先向用户确认**。 */
  readonly needsConfirm: true;
  /** 待删除条数，供 UI 组织文案（如「将永久删除 3 个任务，无法恢复」）。 */
  readonly count: number;
  /** 面向用户的操作名。 */
  readonly action: string;
}

/* ── 查询 ─────────────────────────────────────────────────────────────── */

const SELECT_RECYCLED = `SELECT id, task_id, loop_id, title, description, is_word, is_ok,
                                cpl_time, recurrence, completed_at, reward_points, is_deducted,
                                created_at, priority, deleted_at
                           FROM recycled_tasks`;

/** 回收站列表，`deleted_at DESC`（最近删除的在前，照搬 `getRecycledTasks`）。 */
export function getRecycledTasks(): RecycledTaskRow[] {
  return queryAll<RecycledTaskRow>(
    `${SELECT_RECYCLED} ORDER BY deleted_at DESC`,
    [],
    '读取回收站',
  );
}

/** 回收站条数。 */
export function getRecycledCount(): number {
  return queryScalar('SELECT COUNT(*) FROM recycled_tasks', [], '统计回收站条数', 0);
}

/** 「仅保留最近 N 条」的文案片段，供 UI 直接使用（spec H11）。 */
export function recycleBinLimitHint(): string {
  return `仅保留最近 ${RECYCLE_BIN_LIMIT} 条`;
}

/* ── 移入回收站 ───────────────────────────────────────────────────────── */

/**
 * 把任务移入回收站：插入回收站行 → **在同一事务内裁剪到 ≤10 条** → 删除原任务。
 *
 * 照搬 `TaskRepository.deleteTask` 的单次删除分支（spec D.3）：
 * - `loop_id` **必须**带上，否则循环任务恢复后丢掉循环链；
 * - **只有插入成功才删原任务**；
 * - 裁剪与删除原任务都在**同一事务**。
 *
 * ⚠️ **移入时不清理 `task_tags`**——这是 H4 的裁定。理由：清掉会破坏 H1/H2 的
 * 「恢复后标签自动接回」（恢复时 id 写回原值，这些行自动重新指向真实任务）。
 * 代价是这些行在「该任务被永久删除」前一直挂在 `task_id` 上，
 * **由本文件的三处永久删除路径（裁剪 / 单条永久删除 / 清空）在同事务内清掉**（V1），
 * **不是**靠启动时统一清理。
 *
 * @returns `null` 表示成功；返回字符串表示失败原因（任务不存在 / 插入失败），
 *          与 Flutter「查不到就直接 return，什么都不做」的行为一致
 */
export async function moveTaskToRecycleBin(taskId: number): Promise<string | null> {
  // 先读出完整行（照搬：查不到就直接 return）。
  const task = queryOne<TaskRow>(
    `SELECT id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
            completed_at, reward_points, is_deducted, created_at, priority
       FROM tasks
      WHERE id = ? LIMIT 1`,
    [taskId],
    '读取任务',
  );
  if (!task) return '任务不存在';

  const now = nowLocalIso();

  await runTransaction(async (tx: Tx) => {
    const inserted = await tx.execute(
      `INSERT INTO recycled_tasks
         (task_id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
          completed_at, reward_points, is_deducted, created_at, priority, deleted_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        task.id,
        task.loop_id,
        task.title,
        task.description,
        task.is_word ?? 0,
        task.is_ok ?? 0,
        task.cpl_time,
        task.recurrence ?? 'none',
        task.completed_at,
        task.reward_points ?? 0,
        task.is_deducted ?? 0,
        task.created_at,
        task.priority ?? 'white',
        now,
      ] as never,
    );
    // 「只有插入成功才删原任务」（照搬 `if (recycledId > 0)`）。
    if (inserted.rowsAffected <= 0) {
      throw new RepoError('移入回收站失败：写入回收站未成功');
    }

    // 插入成功后**立刻**在同一事务内裁剪。
    await trimRecycleBinInTx(tx);

    await tx.execute('DELETE FROM tasks WHERE id = ?', [taskId] as never);
  }, '移入回收站');

  return null;
}

/**
 * 事务内裁剪回收站，只保留最近 `RECYCLE_BIN_LIMIT` 条，**并同事务清掉被裁剪条目的
 * 标签关联**（V1）。
 *
 * 照搬 `ORDER BY deleted_at DESC` + `skip(10)` 逐条删（spec D.3）。
 * ⚠️ **刻意不加`, id DESC` 作为次级排序键**：同一毫秒内删多条时`deleted_at` 相同，
 * 加了次级键会改变 Flutter 版在此边界下的行为。spec 明确建议照搬，故从简。
 *
 * ── 为什么不能只用一条 `DELETE ... WHERE id NOT IN (SELECT ...)` ──────────
 * 那条语句**没法连带清`task_tags`**：它删掉哪些行是 SQL 内部的事，
 * JS 侧拿不到被删的 `task_id`。而 V1 要求「任务被永久移出回收站的那一刻，
 * 与该删除同事务清理关联」。⇒ 必须**先查出**被淘汰的行，拿到 `task_id` 映射，
 * 再分两步删。
 *
 * 🔴 **V6 三步，此处三步全部生效**（编号与 `m1-decisions.md` V6 一致）：
 * 1. 条件用 **`task_id`**，永远不用 `recycled_tasks.id`——后者是回收站自己的自增主键；
 * 2. `task_id` **取自本次真正被裁剪的那几行**（`SELECT ... LIMIT -1 OFFSET n` 的结果），
 *    **不是「回收站里所有行」**；
 * 3. 附带 `NOT IN (SELECT id FROM tasks)` 守卫，确保**不会删掉仍活着的任务的关联**。
 *
 * ⚠️ 第 3 步是最隐蔽的一条：前两步写对、逻辑完全正确，**照样能删掉活任务的标签**——
 * 金样本里`task_id=5` 同时存在于 `tasks`（活）与 `recycled_tasks`，
 * 无守卫时 `5|1` 会被静默删掉而任务 5 还在。
 */
export async function trimRecycleBinInTx(tx: Tx): Promise<void> {
  // 第2 步：先查出「本次真正被裁剪的行」——注意 OFFSET 10 之后才是要淘汰的。
  // `task_id` 可能为 NULL（建表可空），逐行判空跳过。
  // 第 2 步：先查出「本次真正被裁剪的行」——注意 OFFSET 10 之后才是要淘汰的。
  // `task_id` 建表可空，NULL 不进入清理集合（无原任务 id 就无从清理关联）。
  const victims = await queryAllInTx<{ id: number; task_id: number | null }>(
    tx,
    `SELECT id, task_id
       FROM recycled_tasks
      ORDER BY deleted_at DESC
      LIMIT -1 OFFSET ?`,
    [RECYCLE_BIN_LIMIT],
  );
  if (victims.length === 0) return;

  // 先删 task_tags —— 必须在删回收站行之前（顺序不可换，见clearRecycleBin 注释）。
  const trimmedTaskIds = victims
    .map(v => v.task_id)
    .filter((id): id is number => id !== null);
  await deleteTaskTagsForDeletedTasks(tx, trimmedTaskIds);

  // 再删回收站行。逐条 DELETE 与「一条 IN (...)」等价，但避免了参数个数上限问题。
  for (const v of victims) {
    await tx.execute('DELETE FROM recycled_tasks WHERE id = ?', [v.id] as never);
  }
}

/**
 * 🔴 **V6 三步的共用实现**：清掉「已被永久删除的任务」的全部标签关联。
 *
 * 这个函数是**所有**永久删除路径唯一的清理入口：
 * - 本文件的三处（裁剪 / 单条永久删除 / 清空）；
 * - `taskRepo.deleteRecurringInstances()`（批量物理删循环实例，V1 补充的第四条路径）——
 *   由 `software-engineer-1` 提出、双方确认统一到这里。
 *
 * **故意做成共用并导出**：V6 三步里最易漏的是第 3 步守卫，而它只是 WHERE 后面多一句、
 * 前两步都对时**代码看起来完全正常**。若每个文件各写一遍 SQL，将来改一处忘一处
 * 就会静默删掉活任务的标签。
 *
 * @param taskId 已确认**不在 `tasks` 中**的原任务 id（即真的被永久删除了）
 *
 * 🔴 **V6 第 3 步在这里生效**：`AND task_id NOT IN (SELECT id FROM tasks)`。
 * 这一句不是冗余，是**防误删活任务标签的唯一防线**。
 * 为什么需要它：H1 让恢复时写回原 `id`，因此**完全可能出现
 * 「`tasks` 里有 id=5 的活任务，同时 `recycled_tasks` 里也有一条 `task_id=5`」**
 * （例如删过又恢复、或历史数据如此）。此时删 `5` 的关联就是**删掉活任务的标签**，
 * 且**任务还在、标签永久丢失、无法找回**。
 * ⚠️ 无守卫时：孤儿数依然是 0（`verify_orphan_cleanup.py` 照样exit 0），
 * **所以这条守卫不会被任何「孤儿数 = 0」的断言发现**——只能靠这里显式写出来。
 *
 * @param taskIds 一批原任务 id；空数组直接返回（不发无意义的 SQL）
 */
export async function deleteTaskTagsForDeletedTasks(
  tx: Tx,
  taskIds: readonly number[],
): Promise<void> {
  if (taskIds.length === 0) return;
  const placeholders = taskIds.map(() => '?').join(', ');
  await tx.execute(
    `DELETE FROM task_tags
      WHERE task_id IN (${placeholders})
        AND task_id NOT IN (SELECT id FROM tasks)`,
    taskIds as never,
  );
}

/* ── 恢复（H1 特批：写回原 id） ────────────────────────────────────────── */

/** 恢复结果。 */
export interface RestoreResult {
  /** 恢复后的任务 id（= 原 id，见 H1）。 */
  readonly taskId: number;
  /** `loop_id`，恢复循环任务时供上层触发回补生成。 */
  readonly loopId: string | null;
  /**
   * **原始**排期时间。
   * ⚠️ 恢复循环任务时必须用**这个旧日期**去触发生成，否则回补窗口会算错
   * （spec D.4 第 4 步）。
   */
  readonly cplTime: string;
  /** 重复规则；上层据此决定是否触发循环回补。 */
  readonly recurrence: string;
}

/**
 * 从回收站恢复任务。
 *
 * ── 与 Flutter 版的关键差异（H1 裁定，**这是修**） ──────────────────────
 *
 * Flutter 版 `restoreTaskFromRecycle` 的 INSERT **不含 `id` 列**，
 * SQLite 会分配一个**全新的 id**。后果（spec D.4①）：
 * `points_records.related_id` 与 `task_tags.task_id` 都还指向**旧 id**，
 * 于是恢复后的任务被结算逻辑当成「从未结算过」→ 用户可以
 * **删任务 → 恢复 → 再完成，无限重复刷分**。这是数据完整性漏洞，不是功能差异。
 *
 * 本实现按 `recycled_tasks.task_id` **写回原 id**：
 * `INSERT INTO tasks (id, ...) VALUES (原id, ...)`。
 * - 原 id 在 `tasks` 中必然不存在（`AUTOINCREMENT` 保证不复用已删除的 id），
 *   所以正常情况下不会主键冲突；
 * - **若真的撞了主键：整个事务回滚并抛 `RepoError`，绝不静默换 id**
 *   （静默换 id 等于把刷分漏洞又放回来）。
 * - `sqlite_sequence` 不会被拉低，恢复后新插入的任务仍拿到更大的 id，不影响后续写入。
 *
 * **副作用（免费拿到）**：H2「恢复任务要不要恢复标签」也随之解决——
 * `task_tags` 里的孤儿行还在（删任务不清关联，H4 裁定），原 id 一对上，
 * 标签**自动接回**，无需任何 schema 变更或额外写入。
 *
 * ⚠️ **已知缺陷，不在 M1 修**（spec H3 裁定照搬）：恢复**循环**任务时，
 * 上层会用**原始 `cplTime`** 触发生成，而生成器「无下界」，所以删掉 3 个月前的
 * 每日任务再恢复，会**一次性补出约 90+ 个实例**。这是产品行为变更而非 bug，
 * M1 照搬并在此注释说明；UI 侧恢复循环任务时应提示「将按现有规则补齐循环实例」。
 *
 * @throws 回收站行不存在 / 主键冲突（均已回滚，零写入）
 */
export async function restoreTaskFromRecycle(recycledTaskId: number): Promise<RestoreResult> {
  return runTransaction(async (tx: Tx) => {
    const row = await queryInTx<RecycledTaskRow>(
      tx,
      `${SELECT_RECYCLED} WHERE id = ? LIMIT 1`,
      [recycledTaskId],
    );
    if (!row) {
      throw new RepoError('恢复任务失败：回收站任务不存在');
    }

    // H1：写回原 id。task_id 建表时可空，但 RN 侧写入时必填——为 null 说明
    // 数据来源异常，此时退回「不指定 id」让 SQLite 分配，并留下明确注释。
    const originalId = row.task_id;

    if (originalId !== null) {
      // 撞主键则整笔回滚抛错，绝不静默换 id（否则等于把刷分漏洞放回来）。
      const clash = await queryInTx<{ c: number }>(
        tx,
        'SELECT 1 AS c FROM tasks WHERE id = ? LIMIT 1',
        [originalId],
      );
      if (clash) {
        throw new RepoError(
          `恢复任务失败：目标任务 id ${originalId} 已被占用，已回滚以避免数据错乱`,
        );
      }
    }

    const inserted = await tx.execute(
      originalId === null
        ? `INSERT INTO tasks
             (loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
              completed_at, reward_points, is_deducted, created_at, priority)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        : `INSERT INTO tasks
             (id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
              completed_at, reward_points, is_deducted, created_at, priority)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      (
        [
          originalId,
          row.loop_id,
          row.title,
          row.description,
          row.is_word ?? 0,
          row.is_ok ?? 0,
          row.cpl_time,
          row.recurrence ?? 'none',
          row.completed_at,
          row.reward_points ?? 0,
          row.is_deducted ?? 0,
          row.created_at,
          row.priority ?? 'white',
        ] as never
      ),
    );
    const taskId = originalId ?? inserted.insertId ?? 0;

    await tx.execute('DELETE FROM recycled_tasks WHERE id = ?', [recycledTaskId] as never);

    return {
      taskId,
      loopId: row.loop_id,
      cplTime: row.cpl_time,
      recurrence: row.recurrence ?? 'none',
    };
  }, '恢复任务');
}

/**
 * 「仅恢复此实例」——**不走 `restoreTaskFromRecycle` 的循环回补**。
 *
 * 照搬 Flutter 的「仅恢复当天」（spec D.5）：先删回收站行，再插入一个
 * `recurrence = 'none'` 的任务。它**不会**触发生成循环实例。
 *
 * ⚠️ Flutter 版这个操作**也会丢原 id**（因为它走的是「删 + 全新插入」）。
 * 本实现**同样写回原 id**——否则就等于开了一个绕过 H1 修复的后门：
 * 用户用「仅恢复此实例」恢复后仍能重复刷分。修复必须覆盖所有恢复入口。
 *
 * ⚠️ **按钮文案与行为不符**（spec D.5）：Flutter 版按钮叫「仅恢复当天」，
 * 实际行为是「只恢复这一个实例、保持**原始日期**、关闭循环」，**不是恢复到今天**。
 * 文案是否改属 UI 决策，本仓储只保证行为。
 */
export async function restoreSingleInstance(recycledTaskId: number): Promise<RestoreResult> {
  return runTransaction(async (tx: Tx) => {
    const row = await queryInTx<RecycledTaskRow>(
      tx,
      `${SELECT_RECYCLED} WHERE id = ? LIMIT 1`,
      [recycledTaskId],
    );
    if (!row) {
      throw new RepoError('恢复任务失败：回收站任务不存在');
    }

    const originalId = row.task_id;
    if (originalId !== null) {
      const clash = await queryInTx<{ c: number }>(
        tx,
        'SELECT 1 AS c FROM tasks WHERE id = ? LIMIT 1',
        [originalId],
      );
      if (clash) {
        throw new RepoError(
          `恢复任务失败：目标任务 id ${originalId} 已被占用，已回滚以避免数据错乱`,
        );
      }
    }

    const inserted = await tx.execute(
      originalId === null
        ? `INSERT INTO tasks
             (loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
              completed_at, reward_points, is_deducted, created_at, priority)
           VALUES ('none', ?, ?, ?, ?, ?, 'none', ?, ?, ?, ?, ?)`
        : `INSERT INTO tasks
             (id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
              completed_at, reward_points, is_deducted, created_at, priority)
           VALUES (?, 'none', ?, ?, ?, ?, 'none', ?, ?, ?, ?, ?)`,
      (
        [
          originalId,
          row.loop_id,
          row.title,
          row.description,
          row.is_word ?? 0,
          row.is_ok ?? 0,
          row.cpl_time,
          row.completed_at,
          row.reward_points ?? 0,
          row.is_deducted ?? 0,
          row.created_at,
          row.priority ?? 'white',
        ] as never
      ),
    );
    const taskId = originalId ?? inserted.insertId ?? 0;

    await tx.execute('DELETE FROM recycled_tasks WHERE id = ?', [recycledTaskId] as never);

    return {
      taskId,
      loopId: row.loop_id,
      cplTime: row.cpl_time,
      recurrence: 'none',
    };
  }, '仅恢复此实例');
}

/* ── 永久删除 / 清空 ──────────────────────────────────────────────────── */

/**
 * 「永久删除某条」的**确认信息**（spec H12 裁定加二次确认）。
 *
 * ⚠️ Flutter 版的回收站卡片 🗑 按钮**无二次确认**，`onPressed` 直接删——
 * 误触即永久丢失、不可逆。这里改为：UI 先调本函数拿到待删条数并弹确认框，
 * 用户确认后才调 `permanentDelete()`。
 *
 * **本仓储不写 UI**，只提供数据。
 */
export function confirmPermanentDelete(recycledTaskId: number): ConfirmableAction {
  const row = queryOne<{ c: number }>(
    'SELECT COUNT(*) AS c FROM recycled_tasks WHERE id = ?',
    [recycledTaskId],
    '检查回收站条目',
  );
  return { needsConfirm: true, count: row?.c ?? 0, action: '永久删除' };
}

/**
 * 「清空回收站」的**确认信息**。
 *
 * Flutter 版清空**有**确认对话框、单条永久删除**没有**——这是不一致的交互，
 * 容易误触。H12 裁定两边都加。
 */
export function confirmClearRecycleBin(): ConfirmableAction {
  return { needsConfirm: true, count: getRecycledCount(), action: '清空回收站' };
}

/**
 * 永久删除单条（**不进回收站、不可恢复**），并**同事务清掉它的标签关联**（V1 补充）。
 *
 * 🔴 **V6 三步**：
 * 1. 条件用 `task_id`（不是 `recycled_tasks.id`）——`deleteTaskTagsForDeletedTask` 内已固化；
 * 2. `task_id` **取自本条**（`SELECT task_id FROM recycled_tasks WHERE id = ?`），
 *    不是回收站里所有行；
 * 3. 守卫 `NOT IN (SELECT id FROM tasks)` 在共用函数内，防止删掉**活任务**的标签。
 *
 * ⚠️ **语句顺序不可换**：必须**先删 `task_tags`**——
 * 取`task_id` 的子查询依赖 `recycled_tasks` 那行还在，先删回收站行就取不到了。
 *
 * ⚠️ 不退还已获得的积分：**不动** `points_records`、**不动** `user_points`
 * （spec D.7）。这是对的——否则「删任务 → 清回收站」就能刷分。
 *
 * ⚠️ 这条从 `writeBatch` 改为**事务形式**：V1 要求「与该删除同事务完成清理」，
 * 而 `writeBatch`（`executeBatch`）无法在两条语句之间传递第一条的结果。
 */
export async function permanentDelete(recycledTaskId: number): Promise<void> {
  await runTransaction(async (tx: Tx) => {
    // 先读出该条目的原任务 id（查不到就什么都不做，与 Flutter 的 delete 语义一致）。
    const row = await queryInTx<{ task_id: number | null }>(
      tx,
      'SELECT task_id FROM recycled_tasks WHERE id = ? LIMIT 1',
      [recycledTaskId],
    );
    if (!row) return;

    // 先删标签关联（task_id 为 NULL 表示历史异常数据，无从清理、跳过）。
    await deleteTaskTagsForDeletedTasks(tx, row.task_id !== null ? [row.task_id] : []);

    // 再删回收站行。
    await tx.execute('DELETE FROM recycled_tasks WHERE id = ?', [recycledTaskId] as never);
  }, '永久删除回收站任务');
}

/**
 * 清空回收站（全表删），并**同事务清掉这批条目的标签关联**（V1）。
 *
 * 🔴 **V6 三步**：
 * 1. 条件用 `task_id`（不是 `recycled_tasks.id`）；
 * 2. `task_id` 取自**回收站里所有行**——这一条是合法的，因为「清空」的定义就是
 *    永久删除全部条目，每一条都该清（V6 第 2 步约束的是「别多删」，
 *    而这里一条都不多删，因为全都要删）；
 * 3. 守卫 `NOT IN (SELECT id FROM tasks)` 仍然生效——**若某条目的`task_id`
 *    对应的任务还活在 `tasks` 里（删过又恢复 / 历史数据），它的标签必须保住**。
 *
 * ⚠️ `WHERE task_id IS NOT NULL`：`task_id` 建表可空，`IN` 遇到 NULL 虽不报错，
 * 但语义要写清楚——**没有原任务 id 的条目无从清理关联，只能删回收站行**。
 *
 * ⚠️ **语句顺序不可换**：必须**先删 `task_tags`**（子查询依赖 `recycled_tasks` 还在）。
 *
 * ⚠️ 仍然**不动** `points_records` / `user_points`（spec D.7）：清空回收站不退还积分，
 * 这是对的，否则「删任务 → 清回收站」就能刷分。
 *
 * 这条从 `writeBatch` 改为**事务形式**，理由同 `permanentDelete`。
 */
export async function clearRecycleBin(): Promise<void> {
  await runTransaction(async (tx: Tx) => {
    // 先取出回收站里全部的 task_id（仅排除 NULL）。
    // ⚠️ 这里**刻意不再写 `NOT IN (SELECT id FROM tasks)`** ——
    // 第 3 步守卫的唯一权威是 `deleteTaskTagsForDeletedTasks` 内部那一条。
    // 两处都写的话，将来改了一处另一处就是陈旧的守卫，
    // 而「守卫在哪个文件」正是 V6 要求收敛的东西。
    // 传入还活着的 task_id 也无害——共用函数会自己跳过。
    const rows = await queryAllInTx<{ task_id: number | null }>(
      tx,
      'SELECT task_id FROM recycled_tasks WHERE task_id IS NOT NULL',
    );
    await deleteTaskTagsForDeletedTasks(
      tx,
      rows.map(r => r.task_id as number),
    );
    await tx.execute('DELETE FROM recycled_tasks', [] as never);
  }, '清空回收站');
}