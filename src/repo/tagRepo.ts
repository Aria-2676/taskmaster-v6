/**
 * 标签仓储：增删改查 + 任务↔标签关联 + 孤儿关联行清理。
 *
 * 对应 Flutter 侧 `database_tag_mixin.dart` + `tag_provider.dart`，
 * 规格见 docs/migration/spec-points-shop.md C 章。
 *
 * ── 关键约束 ───────────────────────────────────────────────────────────
 *
 * - `tags.name` 是 `NOT NULL UNIQUE`，SQLite 默认 **BINARY 排序 → DB 层大小写敏感**；
 *   而 UI 层的重名检查用 `toLowerCase()` 比较 → **大小写不敏感**。
 *   两层语义**不一致且都要保留**（spec C.3 / F25）：结果是可以同时存在
 *   `Work` 和 `work`，但 UI 会以「标签已存在」为由拒绝创建。
 * - **删标签**要手动清 `task_tags`（有清理）；**删任务不清**（产生孤儿）。
 *   这个不对称是既定行为（spec F14）。
 * - **表空时自动播种 4 个系统标签**：用户删光后重启会重新长出来（spec F15）。
 * - `task_tags` 写入一律 `INSERT OR IGNORE`：复合主键天然去重，
 *   重复插入**静默忽略、不报错**（spec F24）。
 * - `tags.color` 是 **`'#RRGGBB'` 字符串**，与 `shop_items.color_value`（ARGB 整数）
 *   **不是一回事**，两者不能共用解析函数（spec B.1 / F16）。
 *   解析用 `core/pointsRules.ts` 的 `parseTagColorArgb`。
 */

import { queryOne, queryAll, queryScalar, writeBatch, nowLocalIso, RepoError } from './base';
import { runTransaction, execInsert, type Tx } from './tx';
import type { TagRow, TaskTagRow } from './types';
import { DEFAULT_TAG_COLOR } from '../core/pointsRules';

/** 新增 / 编辑标签的入参。`id` / `is_system` / `created_at` 不由此处改。 */
export interface NewTag {
  name: string;
  /** `'#RRGGBB'` 字符串；缺省用 `#2196F3`。 */
  color?: string | null;
  /** Material 图标名。⚠️ **纯死数据**，Flutter 侧从未读取它渲染。 */
  icon?: string | null;
}

/** 默认系统标签（表空时播种，4 个）——照搬 `tag_model.dart:76`。 */
const DEFAULT_TAGS: readonly Required<NewTag>[] = [
  { name: '单词', color: '#FF9800', icon: 'translate' },
  { name: '工作', color: '#2196F3', icon: 'work' },
  { name: '学习', color: '#4CAF50', icon: 'school' },
  { name: '生活', color: '#9C27B0', icon: 'home' },
];

/* ── 查询 ─────────────────────────────────────────────────────────────── */

/** 全部标签，`name ASC`（照搬 `getAllTags` 的 `orderBy`）。 */
export function getAllTags(): TagRow[] {
  return queryAll<TagRow>(
    'SELECT id, name, color, icon, is_system, created_at FROM tags ORDER BY name ASC',
    [],
    '读取标签列表',
  );
}

/** 按 id 读单个标签。 */
export function getTagById(id: number): TagRow | undefined {
  return queryOne<TagRow>(
    'SELECT id, name, color, icon, is_system, created_at FROM tags WHERE id = ? LIMIT 1',
    [id],
    '读取标签',
  );
}

/**
 * 按名字查标签，**大小写不敏感**。
 *
 * 对应 UI 层 `getTagByName` 的 `toLowerCase() == toLowerCase()`。
 * ⚠️ 这与 DB 层的 UNIQUE（BINARY、**大小写敏感**）语义不一致，
 * 两个层次都要保留，所以这里用 `LOWER()` 而不是 `=`（spec C.3 / F25）。
 *
 * 多个同名（仅大小写不同）时取**第一行**——与 Flutter 的 `firstWhere` 行为一致。
 */
export function getTagByNameInsensitive(name: string): TagRow | undefined {
  return queryOne<TagRow>(
    'SELECT id, name, color, icon, is_system, created_at FROM tags WHERE LOWER(name) = LOWER(?) LIMIT 1',
    [name],
    '按名称查询标签',
  );
}

/** 某任务的标签，`name ASC`（照搬 `getTagsForTask` 的 INNER JOIN + ORDER BY）。 */
export function getTagsForTask(taskId: number): TagRow[] {
  // INNER JOIN 天然过滤掉 `task_tags` 里的孤儿行（tag_id 指向已删标签）。
  return queryAll<TagRow>(
    `SELECT t.id, t.name, t.color, t.icon, t.is_system, t.created_at
       FROM tags t
       INNER JOIN task_tags tt ON t.id = tt.tag_id
      WHERE tt.task_id = ?
      ORDER BY t.name ASC`,
    [taskId],
    '读取任务标签',
  );
}

/**
 * 某标签关联的任务 id 列表。
 *
 * ⚠️ 照搬 `getTaskIdsByTag`：**无 ORDER BY，且不 JOIN `tasks` 确认存在性**
 * ——所以**可能返回已删任务的 id**（`task_tags` 孤儿行）。spec C.3 明确标注了这点。
 * 若上层要拿去查任务，请自行 `getTaskById` 判空。
 */
export function getTaskIdsByTag(tagId: number): number[] {
  return queryAll<TaskTagRow>(
    'SELECT task_id, tag_id FROM task_tags WHERE tag_id = ?',
    [tagId],
    '读取标签关联任务',
  ).map(row => row.task_id);
}

/* ── 写入 ─────────────────────────────────────────────────────────────── */

/**
 * 新增标签，返回新 id。
 *
 * ⚠️ **调用方应先做重名检查**（`getTagByNameInsensitive`）以给出友好提示，
 * 但本函数**不依赖**那个检查——撞上 UNIQUE 时 `RepoError` 会翻成
 * 「已存在同名记录」。这是有意保留的双层防线。
 */
export async function createTag(tag: NewTag): Promise<number> {
  const name = tag.name.trim();
  if (name.length === 0) {
    throw new RepoError('标签名称不能为空');
  }
  return runTransaction(
    tx =>
      execInsert(
        tx,
        `INSERT INTO tags (name, color, icon, is_system, created_at)
         VALUES (?, ?, ?, 0, ?)`,
        [name, tag.color ?? DEFAULT_TAG_COLOR, tag.icon ?? null, nowLocalIso()],
      ),
    '新增标签',
  );
}

/**
 * 编辑标签：**只能改 `name` 和 `color`**。
 *
 * `is_system` / `icon` / `created_at` 不可改（UI 不提供入口）。
 *
 * ⚠️ **这是修，与 Flutter 版不同**（spec H8 裁定）：
 * Flutter 的 `updateTag` 没有 try/catch，编辑标签名撞上另一个标签的名字时
 * UNIQUE 约束抛出的异常会**直接冒泡导致崩溃**。这里显式包一层，
 * 把异常翻成可展示的「更新标签失败：已存在同名记录」。
 *
 * ⚠️ 注意 UI 层的重名检查**只在新增时做，编辑时不检查**——这是照搬。
 * 所以撞名是正常可达路径，必须在这里兜住（Flutter 版没兜住）。
 *
 * ⚠️ 系统标签**无编辑入口**，但这里不做 `is_system` 拦截——保护放在
 * 调用层（与 Flutter 的 Provider + UI 双层保护一致）。
 */
export async function updateTag(id: number, tag: NewTag): Promise<void> {
  const name = tag.name.trim();
  if (name.length === 0) {
    throw new RepoError('标签名称不能为空');
  }
  return runTransaction(async (tx: Tx) => {
    // `color ?? DEFAULT_TAG_COLOR`：编辑时未传色则保持默认色，
    // 与 Flutter 的 `tag.copyWith(color: tag.color)` 语义一致（构造时已带默认色）。
    await tx.execute('UPDATE tags SET name = ?, color = ? WHERE id = ?', [
      name,
      tag.color ?? DEFAULT_TAG_COLOR,
      id,
    ] as never);
  }, '更新标签');
}

/**
 * 删除标签，并**手动清理 `task_tags`**。
 *
 * ⚠️ 外键 `ON DELETE CASCADE` **从未生效**（代码里没有 `PRAGMA foreign_keys=ON`），
 * 所以这里的 `task_tags` 清理是**必需的**，不是冗余（spec C.3）。
 *
 * ⚠️ 系统标签不可删——**这一层保护在调用方**（Flutter 侧 Provider 与 UI 各拦一次）。
 * @param force 传 `true` 可越过系统标签保护（仅供将来「重置数据」用），默认不越过
 */
export async function deleteTag(id: number, force = false): Promise<void> {
  if (!force) {
    const tag = getTagById(id);
    if (tag && tag.is_system === 1) {
      throw new RepoError('系统标签不可删除');
    }
  }
  await writeBatch(
    [
      // 顺序与 Flutter 一致：先删标签，再清关联。
      ['DELETE FROM tags WHERE id = ?', [id]],
      ['DELETE FROM task_tags WHERE tag_id = ?', [id]],
    ],
    '删除标签',
  );
}

/**
 * 表空时播种 4 个系统标签。
 *
 * ⚠️ 判定条件是「**`tags` 表为空**」，不是「用户没建过标签」。
 * 用户手动删光所有标签后重启，这 4 个系统标签会**重新长出来**（spec C.3 / F15）。
 *
 * @returns 实际插入的条数；表非空时返回 0
 */
export async function seedDefaultTagsIfEmpty(): Promise<number> {
  const count = queryScalar('SELECT COUNT(*) FROM tags', [], '检查标签表', 0);
  if (count > 0) return 0;

  const now = nowLocalIso();
  await writeBatch(
    DEFAULT_TAGS.map(tag => [
      `INSERT INTO tags (name, color, icon, is_system, created_at)
       VALUES (?, ?, ?, 1, ?)`,
      [tag.name, tag.color, tag.icon, now],
    ]),
    '初始化默认标签',
  );
  return DEFAULT_TAGS.length;
}

/* ── 任务 ↔ 标签关联 ─────────────────────────────────────────────────── */

/**
 * 关联单个标签到任务。重复关联**静默忽略**（`INSERT OR IGNORE`）。
 *
 * ⚠️ 不校验 `taskId` / `tagId` 是否存在——照搬。传一个已删的 tagId 会插入
 * `tag_id` 方向的孤儿行（UI 层通过只从现有列表选来规避，spec C.4）。
 */
export function assignTagToTask(taskId: number, tagId: number): Promise<void> {
  return writeBatch(
    [['INSERT OR IGNORE INTO task_tags (task_id, tag_id) VALUES (?, ?)', [taskId, tagId]]],
    '关联标签',
  );
}

/** 解除单个关联。 */
export function removeTagFromTask(taskId: number, tagId: number): Promise<void> {
  return writeBatch(
    [['DELETE FROM task_tags WHERE task_id = ? AND tag_id = ?', [taskId, tagId]]],
    '解除标签关联',
  );
}

/**
 * 全量覆盖某任务的标签集合——**主要的写入路径**（任务表单提交、批量改标签都走它）。
 *
 * ⚠️ Flutter 侧这个函数**不在事务里**：`DELETE` 成功但 `INSERT` 中途失败会导致
 * 任务标签全丢（风险低，因为 `INSERT OR IGNORE` 很难失败）。
 * 这里**包了事务**——修掉这个风险，不改变正常路径行为。
 *
 * ⚠️ `tagIds` 里的重复 id 由 `INSERT OR IGNORE` + 复合主键天然去重。
 * ⚠️ 不校验 tagId 是否存在（照搬）。
 */
export async function setTagsForTask(taskId: number, tagIds: readonly number[]): Promise<void> {
  await runTransaction(async (tx: Tx) => {
    await tx.execute('DELETE FROM task_tags WHERE task_id = ?', [taskId] as never);
    for (const tagId of tagIds) {
      await tx.execute('INSERT OR IGNORE INTO task_tags (task_id, tag_id) VALUES (?, ?)', [
        taskId,
        tagId,
      ] as never);
    }
  }, '设置任务标签');
}

/* ── 孤儿关联行清理 ───────────────────────────────────────────────────── */

/**
 * 统计 `task_tags` 中的孤儿行——分两类，口径与清理函数一致。
 *
 * - `orphanTask`：在 `tasks` **和** `recycled_tasks.task_id` 里都查不到的 `task_id`。
 *   ⚠️ **回收站里任务的关联行不算孤儿**——它们要留着，靠 H1 的 id 保持机制
 *   在恢复时自动接回标签（H2 / H4 裁定）。若把它们清掉，恢复后标签就真的丢了。
 * - `orphanTag`：`tag_id` 指向已删标签的行（删标签时会清，但历史库可能有残留）。
 */
export function countOrphanTaskTags(): { orphanTask: number; orphanTag: number } {
  const taskRow = queryOne<{ c: number }>(
    `SELECT COUNT(*) AS c
       FROM task_tags tt
      WHERE tt.task_id NOT IN (SELECT id FROM tasks)
        AND (tt.task_id NOT IN (SELECT task_id FROM recycled_tasks WHERE task_id IS NOT NULL))`,
    [],
    '统计孤儿任务标签',
  );
  const tagRow = queryOne<{ c: number }>(
    `SELECT COUNT(*) AS c
       FROM task_tags tt
      WHERE tt.tag_id NOT IN (SELECT id FROM tags)`,
    [],
    '统计孤儿标签引用',
  );
  return { orphanTask: taskRow?.c ?? 0, orphanTag: tagRow?.c ?? 0 };
}

/**
 * 清理 `task_tags` 中的孤儿行，返回删除条数。
 *
 * ── 定位已变（V1 裁决）────────────────────────────────────────────────
 * 本函数**不再是主清理机制**，而是**历史遗留脏数据的兜底**。
 * 主清理已下沉到 `recycleRepo` 的三条永久删除路径（裁剪 / 单条永久删除 / 清空回收站），
 * 它们在**任务被永久移出回收站的那一刻**同事务清掉该 `task_id` 的关联（V1 / V1 补充）。
 * ⇒ **本函数不自动调用**，只在 M2 的手动清理入口触发。
 *
 * 为什么当初是「照搬不清理」：只要 id 保持不变，恢复任务后标签会**自动接回**
 * （孤儿行还在 `task_tags` 里，id 对上了就通）——这正是 H1/H2 的成立前提。
 * 现在的分工：**移入时不清**（保住自动接回）、**永久删除时清**（不留垃圾）。
 *
 * ⚠️ 手动调用它会让 `task_tags` 行数变化（`verifyGolden` 的行数检查会漂移），
 * 所以**不要在启动时自动跑**——迁移验收依赖「迁移前后行数一致」。
 *
 * @param alsoCleanDanglingTags 是否顺带清 `tag_id` 指向已删标签的行。
 *        默认 `true`——这类行永远没有恢复价值（标签已不存在），
 *        且 `getTagsForTask` 用 INNER JOIN 本来就看不见它们。
 */
export async function purgeOrphanTaskTags(alsoCleanDanglingTags = true): Promise<number> {
  const before = countOrphanTaskTags();
  const actions: Array<[string, unknown[]]> = [
    [
      `DELETE FROM task_tags
        WHERE task_id NOT IN (SELECT id FROM tasks)
          AND task_id NOT IN (SELECT task_id FROM recycled_tasks WHERE task_id IS NOT NULL)`,
      [],
    ],
  ];
  if (alsoCleanDanglingTags) {
    actions.push(['DELETE FROM task_tags WHERE tag_id NOT IN (SELECT id FROM tags)', []]);
  }
  await writeBatch(actions, '清理孤儿标签关联');
  return before.orphanTask + before.orphanTag;
}