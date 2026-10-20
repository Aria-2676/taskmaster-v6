/**
 * 设置仓储：`settings` 表的 key-value 读写。
 *
 * **为什么补这个**：设置层本来打算直接裸写 SQL，但那违反本项目的铁律——
 * 「界面与 store 都不碰 SQL，一律走 src/repo」。
 * `settings` 就两列（`key TEXT PRIMARY KEY, value TEXT NOT NULL`），
 * 与其让上层各处各写一份，不如收在这里，也让读写口径只有一个地方。
 *
 * ── 关键约束 ───────────────────────────────────────────────────────────
 *
 * - 首次启动已由 `src/db/schema.ts` 的 `SEED_SQL` 播种 **16 个键**，
 *   所以绝大多数键**一定存在**，`getSetting` 返回 null 通常意味着键名写错了。
 * - 用 `INSERT OR REPLACE` 而不是 `ON CONFLICT ... DO UPDATE`：
 *   前者从很早的 SQLite 版本就支持，后者要 3.24+。这张表只有两列，
 *   REPLACE 的「先删后插」没有副作用，没必要为了语义好看去赌 SQLite 版本。
 * - 值一律是 **TEXT**。布尔存 `'true'/'false'`、数字存十进制字符串，
 *   转换交给上层（`SettingsStoreState` 的 getBool / getInt），
 *   这里**不做隐式转换**——隐式转换正是 v5 里那些「'false' 被当成真」的由来。
 */

import { queryAll, queryOne, writeBatch } from './base';

const UPSERT_SQL = 'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)';

/** 整表读出为普通对象。键按 `key ASC` 排，方便调试时看。 */
export function getAllSettings(): Record<string, string> {
  const rows = queryAll<{ key: string; value: string }>(
    'SELECT key, value FROM settings ORDER BY key ASC',
    [],
    '读取设置表',
  );
  const out: Record<string, string> = {};
  for (const r of rows) out[r.key] = r.value;
  return out;
}

/**
 * 读单个键。**不存在时返回 null，不给默认值**——
 * 默认值该由调用方决定，仓储层默默塞一个 fallback 会让「键名拼错了」伪装成正常。
 */
export function getSetting(key: string): string | null {
  const row = queryOne<{ value: string }>(
    'SELECT value FROM settings WHERE key = ? LIMIT 1',
    [key],
    '读取设置项',
  );
  return row?.value ?? null;
}

/** 写入 / 更新一个键。 */
export async function setSetting(key: string, value: string): Promise<void> {
  await writeBatch([[UPSERT_SQL, [key, value]]], '写入设置项');
}

/** 批量写入。传空对象时直接返回，不空跑一次 writeBatch。 */
export async function setSettings(pairs: Record<string, string>): Promise<void> {
  const actions = Object.entries(pairs).map(
    ([k, v]) => [UPSERT_SQL, [k, v]] as [string, unknown[]],
  );
  if (actions.length === 0) return;
  await writeBatch(actions, '批量写入设置项');
}

/**
 * 删除一个键。
 *
 * ⚠️ 删掉已播种的键**不会**让它恢复默认值——
 * `SEED_SQL` 只在建表时跑一次。真要恢复默认值，由上层显式写回。
 */
export async function deleteSetting(key: string): Promise<void> {
  await writeBatch([['DELETE FROM settings WHERE key = ?', [key]]], '删除设置项');
}
