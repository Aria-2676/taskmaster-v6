/**
 * 数据库入口
 *
 * 本项目现在是**独立的新 app**（包名 `com.noteapp.taskmaster.v6`，库名 `tasks.db`），
 * **不要求与 Flutter v5 的数据兼容**——所以这里的 `tasks.db` 是**本 app 自己的库**，
 * 不是「读 v5 留下的库」。
 *
 * 仍需遵守的约束（沿用 `docs/migration/schema-v3.md` 的表结构定义，schema 本身仍然有效）：
 * - 文件位于应用私有目录的 `databases/tasks.db`；
 * - 时间是 ISO8601 **本地**字符串，不要按 UTC 解析；
 * - 布尔是 0/1，`scratch_tickets` 的两个状态列可能为 NULL；
 * - `PRAGMA foreign_keys` **不要依赖**：外键从未开启，删任务时关联行不会被级联清理。
 */

import { open, ANDROID_DATABASE_PATH } from '@op-engineering/op-sqlite';
import { CREATE_TABLES, CREATE_INDEXES, SEED_SQL } from './schema';

export const DB_NAME = 'tasks.db';

export type DB = ReturnType<typeof open>;

let cached: DB | null = null;

/**
 * 打开数据库；**首次运行时自动建表 + 播种**。
 *
 * ⚠️ 现在是**独立的新 app**（包名 `com.noteapp.taskmaster.v6`、库名 `tasks.db`），
 * 全新安装时**沙箱里没有任何库**——所以「建表」不能再假设「库已由迁移准备好」。
 * 首次启动必须：建表 → 建索引 → 播种（`user_points` 单行 + `pomodoro_settings` 单行 + 4 个默认标签）。
 *
 * 幂等：`CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` / `INSERT OR IGNORE`，
 * 每次启动都跑一遍也无副作用。
 */
export function openDatabase(location: string = ANDROID_DATABASE_PATH): DB {
  if (cached) return cached;
  cached = open({ name: DB_NAME, location });
  ensureSchema(cached);
  return cached;
}

/**
 * 建表 + 建索引 + 播种（幂等）。
 *
 * 为什么单独一个函数：它需要**在建索引之前建表**（索引依赖表存在），
 * 而且**播种必须在建表之后**（`SEED_SQL` 往表里插行）。
 * 任何一条失败都要让调用方看见——静默失败会变成「运行时才炸的表不存在」。
 */
function ensureSchema(db: DB): void {
  try {
    db.executeSync(CREATE_TABLES);
    db.executeSync(CREATE_INDEXES);
    db.executeSync(SEED_SQL);
  } catch (e) {
    throw new Error(
      `初始化数据库失败（${DB_NAME}）：${e instanceof Error ? e.message : String(e)}`,
    );
  }
}

export function closeDatabase(): void {
  if (cached) {
    cached.close();
    cached = null;
  }
}

/** 读一张表的行数。 */
export function countRows(db: DB, table: string): number {
  const res = db.executeSync(`SELECT COUNT(*) AS c FROM ${table}`);
  const rows = res.rows as Array<{ c: number }>;
  return rows[0]?.c ?? 0;
}

/** 余额与流水净额（必须相等，否则说明历史数据已经不自洽）。 */
export function readBalance(db: DB): { balance: number; ledgerSum: number } {
  const res = db.executeSync(`
    SELECT (SELECT points FROM user_points WHERE id = 1) AS balance,
           (SELECT COALESCE(SUM(points), 0) FROM points_records) AS ledger_sum
  `);
  const row = (res.rows as Array<{ balance: number; ledger_sum: number }>)[0];
  return { balance: row?.balance ?? 0, ledgerSum: row?.ledger_sum ?? 0 };
}

/**
 * 孤儿关联：旧版从未开启外键，这里显式检查，不假设级联生效过。
 *
 * ⚠️ **口径（U4 裁决）**：`task_tags.task_id` 的宿主是「活着的任务」**或**「还在回收站里的任务」。
 * 回收站里的任务在 `tasks` 表中**没有对应行**，但它的标签关联**不是孤儿**——
 * 恢复任务时（写回原 id）靠这行关联自动接回标签（V4 / H2）。
 * 所以孤儿 = 在 `tasks` **与** `recycled_tasks` 中**都**找不到的 `task_id`。
 *
 * ⚠️ 旧口径（只 join `tasks`）会把回收站任务的关联算成孤儿，
 * 于是「用户删过任务 ⇒ 孤儿数 > 0」，迁移验收就永远不通过。
 * 这个定义与 `schema-v3.md §7` 的验收 SQL、`tool/verify_orphan_cleanup.py` 完全一致。
 *
 * 两个维度要分开看（V7）：
 * - `taskTags`：`task_id` 找不到宿主；
 * - `tagRefs`：`tag_id` 指向已删除的标签（删标签时的清理只覆盖新数据，历史残留仍在）。
 */
export function countOrphans(db: DB): { taskTags: number; tagRefs: number } {
  const a = db.executeSync(`
    SELECT COUNT(*) AS c FROM task_tags tt
      LEFT JOIN tasks t ON t.id = tt.task_id
      LEFT JOIN recycled_tasks r ON r.task_id = tt.task_id
     WHERE t.id IS NULL AND r.id IS NULL
  `);
  const b = db.executeSync(`
    SELECT COUNT(*) AS c FROM task_tags tt
    LEFT JOIN tags g ON g.id = tt.tag_id WHERE g.id IS NULL
  `);
  return {
    taskTags: ((a.rows as Array<{ c: number }>)[0]?.c) ?? 0,
    tagRefs: ((b.rows as Array<{ c: number }>)[0]?.c) ?? 0,
  };
}

/** 时间格式抽样：统计不符合 `YYYY-MM-DDTHH:MM:SS` 前缀的行数。 */
export function countBadTimestamps(db: DB): number {
  const res = db.executeSync(`
    SELECT COUNT(*) AS c FROM tasks
     WHERE cpl_time NOT LIKE '____-__-__T__:__:%'
        OR created_at NOT LIKE '____-__-__T__:__:%'
  `);
  return ((res.rows as Array<{ c: number }>)[0]?.c) ?? 0;
}
