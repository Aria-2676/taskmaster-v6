/**
 * 回收站清理逻辑的**设计自检**（无需设备、无需 RN 依赖）
 *
 * 运行（仓库根 rn/ 下）：
 *   node --experimental-strip-types src/core/__tests__/recycle.test.ts
 *
 * ## 为什么这些测试长这样（不是"随便造点数据"）
 *
 * 🔴 **V6 的核心陷阱**：单测如果只用 `id === task_id` 的数据，
 * **错误实现同样会「通过」**。V6 裁决原文：
 * > **单测必须用 `id ≠ task_id` 的数据**，并加**反向断言**：其他活任务的标签关联原样保留。
 *   否则错误实现同样会「通过」——这是本条最容易被单测放过的地方。
 *
 * 所以本文件里每一条都用**故意错位**的数据（`recycledId ≠ taskId`），
 * 并且**断言的是"不该被删的还在"**，而不只是"该删的没了"。
 *
 * ## 为什么测的是 SQL 而不是仓储函数
 *
 * `recycleRepo.ts` 依赖 op-sqlite 原生模块，在 Node 里跑不起来。
 * 但**这条风险的实质在 SQL 的列选择与守卫条件上**，不在 TS 编排上。
 * 所以这里把 `recycleRepo` 里的 SQL 原样抽出来，用一个**纯 JS 的迷你 SQLite 语义**
 * 跑不通——改为**用与实现完全一致的 SQL 文本 + 手写数据推演**，
 * 把「哪些task_id 该删、哪些不该删」这个判定显式写出来。
 *
 * ⚠️ **诚实说明**：本文件**不验证 RN 代码真的这么执行**（那要真机冒烟）。
 * 它验证的是**判定口径**：给定一组 task_id 关系，该删哪些、不该删哪些。
 * `tool/verify_orphan_cleanup.py` 用真实 SQLite 补上了运行时那一半。
 */

import assert from 'node:assert/strict';

/** 一次清理决策的输入：回收站里有哪些条目。 */
interface RecycledRow {
  /** `recycled_tasks.id` —— 回收站自己的自增主键（**不是** task_id）。 */
  recycledId: number;
  /** `recycled_tasks.task_id` —— 原任务的 `tasks.id`；建表可空。 */
  taskId: number | null;
  deletedAt: string;
}

/** `task_tags` 的一行。 */
interface TaskTag {
  taskId: number;
  tagId: number;
}

/**
 * 🔴 **V6 三步的判定核心**，与 `recycleRepo.ts` 的 SQL 一一对应。
 *
 * 对应 SQL（`deleteTaskTagsForDeletedTask`）：
 * ```sql
 * DELETE FROM task_tags
 *  WHERE task_id = ?
 *    AND task_id NOT IN (SELECT id FROM tasks)
 * ```
 *
 * @param taskId   待清理的原任务 id
 * @param aliveIds 当前 `tasks` 表里**仍然活着**的任务 id 集合
 * @returns 是否应当删除该 task_id 的标签关联
 */
export function shouldDeleteTaskTags(taskId: number, aliveIds: ReadonlySet<number>): boolean {
  // 第 1 步已由调用方保证（传进来的是 task_id，不是 recycled_tasks.id）；
  // 这里实现第 3 步：活着的任务的关联一律不删。
  return !aliveIds.has(taskId);
}

/**
 * 🔴 **V6 第 2 步**：裁剪时只能清「本次真正被裁剪的那几行」的关联。
 *
 * 对应 SQL：`SELECT id, task_id FROM recycled_tasks ORDER BY deleted_at DESC LIMIT -1 OFFSET n`
 */
export function pickTrimmedRows(
  rows: readonly RecycledRow[],
  keep: number,
): RecycledRow[] {
  const ordered = [...rows].sort((a, b) =>
    a.deletedAt === b.deletedAt ? 0 : a.deletedAt < b.deletedAt ? 1 : -1,
  );
  return ordered.slice(keep);
}

/**
 * 🔴 **V6 第 2 步（清空场景的特例）**：清空回收站时「所有行」都是被永久删除的，
 * 因此**一条不多删**——但第 3 步守卫**依然生效**。
 */
export function pickAllRowsForClear(rows: readonly RecycledRow[]): RecycledRow[] {
  return [...rows];
}

let passed = 0;
const failures: string[] = [];

function test(name: string, fn: () => void): void {
  try {
    fn();
    passed += 1;
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures.push(`${name}: ${(error as Error).message}`);
    console.log(`FAIL  ${name}`);
    console.log(`      ${(error as Error).message}`);
  }
}

/** 断言 task_tags 的最终内容（顺序无关）。 */
function assertTags(actual: TaskTag[], expected: Array<[number, number]>, msg: string): void {
  const norm = actual
    .map(t => `${t.taskId}|${t.tagId}`)
    .sort()
    .join(' ');
  const want = expected.map(([a, b]) => `${a}|${b}`).sort().join(' ');
  if (norm !== want) {
    throw new Error(`${msg}\n  实际：${norm}\n  期望：${want}`);
  }
}

/* ── 固定测试数据：`id ≠ task_id`（V6 的核心前提） ───────────────────── */

const RECYCLED: RecycledRow[] = [
  // recycledId=1 → taskId=5；recycledId=2 → taskId=99（全都不相等）
  { recycledId: 1, taskId: 5, deletedAt: '2026-01-30T09:00:00.000' },
  { recycledId: 2, taskId: 99, deletedAt: '2026-01-29T09:00:00.000' },
];

/** `tasks` 表里活着的任务。**注意 5 在里面**——这正是 V6 第 3 步的雷。 */
const ALIVE = new Set([1, 2, 3, 4, 5, 6, 8, 9, 10]);

/* ── V6 第 1 步：用哪个列 ─────────────────────────────────────────────── */

test('V6 第1步：recycledId 与 taskId 是不同的列，不可互换', () => {
  assertTags(
    RECYCLED.map(r => ({ taskId: r.recycledId, tagId: 1 })),
    [[1, 1], [2, 1]],
    'recycledId 集合',
  );
  // 拿 recycledId（1,2）去删：1 和 2 都活在 tasks 里 → 守卫会保住它们
  // ⇒ 结果是「该清的 99 没清掉」，即**漏清**（孤儿残留）。
  // 注意这是**守卫存在时的**表现；守卫不存在时后果是**误删活任务**（见下方两条）。
  const wrong = RECYCLED.filter(r => !shouldDeleteTaskTags(r.recycledId, ALIVE));
  assertTags(
    wrong.map(r => ({ taskId: r.recycledId, tagId: 1 })),
    [[1, 1], [2, 1]],
    '用 recycledId 时，因活任务守卫而全部被保住（该清的没清）',
  );
  // 拿 taskId（5,99）去删：5 因活着被守卫保住，99 真被删所以该清。
  // ⚠️ `taskId` 建表可空，判空后才参与判定（与 `recycleRepo` 的 `!== null` 一致）。
  const right = RECYCLED.filter(
    r => r.taskId !== null && !shouldDeleteTaskTags(r.taskId, ALIVE),
  );
  assertTags(
    right.map(r => ({ taskId: r.taskId as number, tagId: 1 })),
    [[5, 1]],
    '用 taskId + 守卫后应清的关联',
  );
});

/* ── V6 第 3 步：守卫（最容易漏的一步） ─────────────────────────────── */

test('V6 第3步：活着的任务的标签关联一律不删（金样本 task_id=5 就是活任务）', () => {
  assert.equal(shouldDeleteTaskTags(5, ALIVE), false, 'task 5 活着，必须保留');
  assert.equal(shouldDeleteTaskTags(99, ALIVE), true, 'task 99 不存在，该清');
});

test('🔴 V6 第3步反向断言：误用 recycledId 会删掉活任务 1、2 的关联', () => {
  // 这是本文件最核心的一条：证明「拿错列」的后果是真实的数据丢失。
  const before: TaskTag[] = [
    { taskId: 1, tagId: 1 },
    { taskId: 2, tagId: 2 },
    { taskId: 4, tagId: 2 },
    { taskId: 5, tagId: 1 },
    { taskId: 99, tagId: 1 },
  ];
  // 错误实现：DELETE ... WHERE task_id IN (<recycledId>)
  const wrongAfter = before.filter(t => !RECYCLED.some(r => r.recycledId === t.taskId));
  assertTags(
    wrongAfter,
    [[4, 2], [5, 1], [99, 1]],
    '错误实现后的 task_tags',
  );
  // 活任务 1、2 的关联确实被静默删掉了 —— 这就是 V6 要防的事故。
  assert.equal(wrongAfter.some(t => t.taskId === 1), false, '活任务 1 的关联被误删');
  assert.equal(wrongAfter.some(t => t.taskId === 2), false, '活任务 2 的关联被误删');
});

test('🔴 V6 第3步反向断言：正确实现 + 守卫后，活任务关联一条都不丢', () => {
  const before: TaskTag[] = [
    { taskId: 1, tagId: 1 },
    { taskId: 2, tagId: 2 },
    { taskId: 4, tagId: 2 },
    { taskId: 5, tagId: 1 },
    { taskId: 99, tagId: 1 },
  ];
  const after = before.filter(t => !shouldDeleteTaskTags(t.taskId, ALIVE));
  assertTags(after, [[1, 1], [2, 2], [4, 2], [5, 1]], '正确实现后的 task_tags');
  // 逐条确认活任务（1/2/4/5）全部保住。
  for (const alive of [1, 2, 4, 5]) {
    assert.ok(
      after.some(t => t.taskId === alive),
      `活任务 ${alive} 的关联被误删`,
    );
  }
});

/* ── V6 第 2 步：删哪些行 ─────────────────────────────────────────────── */

test('V6 第2步：裁剪只取「本次真正被裁剪的那几行」，不是回收站全部', () => {
  const trimmed = pickTrimmedRows(RECYCLED, 1);
  assert.equal(trimmed.length, 1, 'keep=1 时只裁剪 1 行');
  assert.equal(trimmed[0].recycledId, 2, '被裁剪的应是 deleted_at 较旧的那行');
  assert.equal(trimmed[0].taskId, 99);
});

test('V6 第2步：不足上限时裁剪不到任何行（不产生多余清理）', () => {
  assert.equal(pickTrimmedRows(RECYCLED, 10).length, 0);
});

test('V6 第2步：deleted_at 并列时按原顺序稳定，不引入新的排序键', () => {
  const tied: RecycledRow[] = [
    { recycledId: 7, taskId: 70, deletedAt: '2026-01-01T00:00:00.000' },
    { recycledId: 8, taskId: 80, deletedAt: '2026-01-01T00:00:00.000' },
  ];
  const trimmed = pickTrimmedRows(tied, 1);
  assert.equal(trimmed.length, 1);
  assert.equal(trimmed[0].recycledId, 8, '并列时应保留原顺序，不按 id 二次排序');
});

test('V6 第2步：裁剪后清掉的关联只属于被裁剪的那几行', () => {
  const before: TaskTag[] = [
    { taskId: 5, tagId: 1 },  // 保留行（recycledId=1）→ 且任务活着 → 保留
    { taskId: 99, tagId: 1 }, // 被裁剪行（recycledId=2）→ 任务不存在 → 清掉
    { taskId: 4, tagId: 2 },  // 别的活任务 → 保留
  ];
  const trimmed = pickTrimmedRows(RECYCLED, 1);
  const trimmedTaskIds = trimmed.map(r => r.taskId);
  const after = before.filter(
    t => !(shouldDeleteTaskTags(t.taskId, ALIVE) && trimmedTaskIds.includes(t.taskId)),
  );
  assertTags(after, [[5, 1], [4, 2]], '裁剪后的 task_tags');
  assert.ok(after.some(t => t.taskId === 5), '保留行的关联不该被清');
});

test('V6 第2步：task_id 为 NULL 的条目跳过清理（建表可空）', () => {
  const rows: RecycledRow[] = [{ recycledId: 3, taskId: null, deletedAt: '2026-01-01T00:00:00.000' }];
  const before: TaskTag[] = [{ taskId: 4, tagId: 2 }];
  // taskId 为 null → 不进入清理集合（实现里是 `if (taskId !== null)` 判空）
  const trimmed = pickTrimmedRows(rows, 0);
  const nullableIds = trimmed.map(r => r.taskId).filter((v): v is number => v !== null);
  const after = before.filter(
    t => !(shouldDeleteTaskTags(t.taskId, ALIVE) && nullableIds.includes(t.taskId)),
  );
  assertTags(after, [[4, 2]], 'task_id 为 NULL 时不应误删任何关联');
});

/* ── 清空回收站：一条不多删，但守卫依然生效 ───────────────────────────── */

test('清空回收站：全选所有行（V6 第2步在清空场景的特例）', () => {
  assert.equal(pickAllRowsForClear(RECYCLED).length, 2);
});

test('清空回收站：仍受第 3 步守卫约束，活任务关联不丢', () => {
  const before: TaskTag[] = [
    { taskId: 1, tagId: 1 },
    { taskId: 5, tagId: 1 },
    { taskId: 99, tagId: 1 },
  ];
  const all = pickAllRowsForClear(RECYCLED);
  const inBin = new Set(all.map(r => r.taskId));
  const after = before.filter(
    t => !(inBin.has(t.taskId) && shouldDeleteTaskTags(t.taskId, ALIVE)),
  );
  assertTags(after, [[1, 1], [5, 1]], '清空后的 task_tags');
  assert.ok(after.some(t => t.taskId === 5), '活任务 5 在回收站里有关联，清空也不能删');
});

test('清空回收站：task_id 为 NULL 的条目不产生删除条件（IS NOT NULL）', () => {
  const rows: RecycledRow[] = [
    { recycledId: 1, taskId: null, deletedAt: '2026-01-01T00:00:00.000' },
    { recycledId: 2, taskId: 99, deletedAt: '2026-01-02T00:00:00.000' },
  ];
  const inBin = new Set(rows.map(r => r.taskId).filter((v): v is number => v !== null));
  assert.deepEqual([...inBin], [99], 'NULL 不应进入 IN 集合');
});

/* ── 幂等性与顺序 ─────────────────────────────────────────────────────── */

test('幂等：重复清空不报错、不改变结果', () => {
  const before: TaskTag[] = [{ taskId: 99, tagId: 1 }];
  const apply = (tags: TaskTag[]) =>
    tags.filter(t => !shouldDeleteTaskTags(t.taskId, ALIVE));
  const once = apply(before);
  const twice = apply(once);
  assertTags(once, [], '第一次');
  assertTags(twice, [], '第二次');
  assert.equal(once.length, twice.length, '重复执行结果必须一致');
});

test('顺序：先删 task_tags 再删 recycled_tasks（子查询依赖后者还在）', () => {
  // 模拟 permanentDelete 的两步顺序；若顺序颠倒，第二步取不到 task_id。
  const bin = new Map<number, number | null>([[1, 99]]);
  const taskIdFirst = bin.get(1);
  const cleaned = taskIdFirst !== null && taskIdFirst !== undefined
    ? shouldDeleteTaskTags(taskIdFirst, ALIVE)
    : false;
  assert.equal(cleaned, true, '先删 task_tags 时能取到 task_id 并完成清理');
  bin.delete(1);
  // 若顺序颠倒，此时再查就取不到了——这正是「顺序不可换」的原因。
  assert.equal(bin.has(1), false, '删完回收站行后 task_id 已无从取得');
});

/* ── 结果 ────────────────────────────────────────────────────────────── */

console.log('');
console.log(`passed=${passed} failed=${failures.length}`);
if (failures.length > 0) {
  console.log('RESULT=FAIL');
  process.exitCode = 1;
} else {
  console.log('RESULT=PASS');
}