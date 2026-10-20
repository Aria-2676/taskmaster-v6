/**
 * 仓储层的公共地基：事务、类型映射、时间格式。
 *
 * 为什么单独抽一层：M1 的任务 / 标签 / 积分 / 商城 / 回收站五个模块，
 * 每一个都要写库、都要事务、都要处理 `0/1 ↔ boolean` 和 ISO 时间字符串。
 * 这些规则散落在各处是最容易「重写走样」的地方——Flutter 侧是在
 * `lib/core/services/database/` 的 mixin 里各写一遍，靠人肉保持一致。
 * 这里收口一次，让所有仓储都走同一条路径。
 *
 * 对应 Flutter 侧：`database_gateway.dart` + `database_*_mixin.dart`。
 */

import { openDatabase, type DB } from '../db';

/** 仓库层的错误类型：带上「用户能看懂」的中文消息，供 UI 直接展示。 */
export class RepoError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'RepoError';
  }
}

/**
 * 把 op-sqlite 抛出的原始错误翻译成可展示的中文消息。
 *
 * 背景：op-sqlite 的报错是 SQLite 原文（例如 `UNIQUE constraint failed: ...`），
 * 直接弹给用户等于没弹。这里只做**已知的、可确定的**映射；
 * 映射不到的原样抛出，避免把未知问题伪装成已知问题、丢掉排查线索。
 */
export function toRepoError(e: unknown, action: string): RepoError {
  if (e instanceof RepoError) return e;
  const raw = e instanceof Error ? e.message : String(e);

  const known: Array<[RegExp, string]> = [
    [/UNIQUE constraint failed: ([\w.]+)/, '已存在同名记录'],
    [/NOT NULL constraint failed: ([\w.]+)/, '必填项缺失'],
    [/FOREIGN KEY constraint failed/, '关联数据不存在'],
    [/CHECK constraint failed/, '数据不满足约束'],
    [/no such table: ([\w]+)/, '数据库结构缺失，请重新安装应用'],
    [/no such column: ([\w]+)/, '数据库结构不兼容，请更新应用'],
    [/database is locked/i, '数据库正忙，请稍后重试'],
    [/disk I\/O error/i, '存储写入异常，请检查可用空间'],
  ];
  for (const [re, msg] of known) {
    if (re.test(raw)) return new RepoError(`${action}失败：${msg}`, e);
  }
  return new RepoError(`${action}失败：${raw}`, e);
}

/**
 * 在单个事务里执行一批写操作，**任何一条失败则整体回滚**。
 *
 * 对应 Flutter 侧的 `db.transaction((txn) async {...})`。
 * 关键约束：调用方**不要**在 `fn` 内部用 `executeSync` 写库——
 * `executeSync` 走的是另一条执行路径，在事务内混用会出现「事务提交了但部分语句没进去」。
 * 所以这里用 `executeBatch`（内部自动包事务），并把 SQL 交给它一次性执行。
 *
 * @param actions 待执行语句，元素是 [SQL, 参数] 或 SQL 字符串（无参数）
 */
export async function writeBatch(actions: Array<[string, unknown[]]>, action: string): Promise<void> {
  if (actions.length === 0) return;
  const db = openDatabase();
  const commands = actions.map(([sql, params]) => ({ sql, params: params as never }));
  try {
    await db.executeBatch(commands as never);
  } catch (e) {
    throw toRepoError(e, action);
  }
}

/** 同步读一条记录（无结果返回 undefined）。 */
export function queryOne<T>(sql: string, params: unknown[], action: string): T | undefined {
  const db = openDatabase();
  try {
    const res = db.executeSync(sql, params as never);
    const rows = res.rows as T[];
    return rows[0];
  } catch (e) {
    throw toRepoError(e, action);
  }
}

/** 同步读多行。 */
export function queryAll<T>(sql: string, params: unknown[], action: string): T[] {
  const db = openDatabase();
  try {
    const res = db.executeSync(sql, params as never);
    return res.rows as T[];
  } catch (e) {
    throw toRepoError(e, action);
  }
}

/** 同步读单个标量（COUNT / SUM 等）。 */
export function queryScalar(sql: string, params: unknown[], action: string, fallback = 0): number {
  const row = queryOne<Record<string, unknown>>(sql, params, action);
  if (!row) return fallback;
  const v = Object.values(row)[0];
  return typeof v === 'number' ? v : fallback;
}

// ── 时间格式 ────────────────────────────────────────────────────────────
// 数据契约见 docs/migration/schema-v3.md：
// 时间列是 **ISO8601 本地字符串**，无时区后缀；不是时间戳，也不是 UTC。
// RN 侧一律走 `nowLocalIso()` 写库、`localIsoToday()` 取当天边界，
// 杜绝各模块各写一份 `new Date().toISOString()`（那是 UTC，会和历史数据差 8 小时）。

/** 两位补零。 */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/** 三位补零（毫秒）。 */
function pad3(n: number): string {
  return n < 10 ? `00${n}` : n < 100 ? `0${n}` : String(n);
}

/**
 * 当前本地时间，格式 `YYYY-MM-DDTHH:mm:ss.SSS`。
 *
 * **为什么是 3 位小数而 Dart 常输出 6 位**：Dart 的 `toIso8601String()` 规则是
 * 「微秒为 0 输出 3 位、非 0 输出 6 位」，而真机 `DateTime.now()` 带微秒精度，
 * 所以历史数据绝大多数是 6 位。JS `Date` 只有毫秒精度，无法复刻那个分支。
 * 统一写 3 位。两者的**排序与区间比较仍然正确**（小数部分字典序等价于数值序），
 * 但按字符串严格相等去比对新旧数据会失败——要比到秒请用 `SUBSTR(col,1,19)`。
 * 详见 docs/migration/schema-v3.md §1。
 */
export function nowLocalIso(d: Date = new Date()): string {
  return (
    `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` +
    `T${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`
  );
}

/** 本地日期 `YYYY-MM-DD`。 */
export function localDate(d: Date = new Date()): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/**
 * 「今天」的半开区间 `[今日 00:00:00, 明日 00:00:00)`，用于字符串区间查询。
 *
 * 与桌面小组件的 `todayRange()` 同口径：ISO8601 定长前缀的字典序 == 时间序，
 * 所以可以直接做 SQL 字符串比较并命中 `idx_*_cpl_time` 索引。
 */
export function localTodayRange(d: Date = new Date()): { start: string; end: string } {
  const start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0);
  const end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0);
  return { start: isoMinute(start), end: isoMinute(end) };
}

/** 本地时间，精确到秒（`YYYY-MM-DDTHH:mm:ss`），用于与「整秒」构造的历史数据对齐。 */
export function isoMinute(d: Date): string {
  return (
    `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` +
    `T${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
  );
}

// ── 值映射 ──────────────────────────────────────────────────────────────
// 数据契约：布尔在库里是 INTEGER 0/1（不是 NULL，也不是 true/false）。

/** 库里读出的 0/1/NULL → boolean。`null` 视为 false（谨慎：老库可能缺列）。 */
export function toBool(v: unknown): boolean {
  return v === 1 || v === true || v === '1';
}

/** boolean → 库里要写的 0/1。 */
export function fromBool(v: boolean): number {
  return v ? 1 : 0;
}

/** 可空布尔：`null` 原样保留（`scratch_tickets.is_scratched` 可能是 NULL）。 */
export function toBoolOrNull(v: unknown): boolean | null {
  return v === null || v === undefined ? null : toBool(v);
}

/** 数据库句柄（仅在需要跨模块组合查询时用，多数场景走上面的辅助函数）。 */
export function db(): DB {
  return openDatabase();
}