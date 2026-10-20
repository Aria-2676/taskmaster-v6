/**
 * 番茄钟读写（同步 SQL）
 *
 * 对应 docs/migration/schema-v3.md §2.7。三条硬约束（来自 §1 存储约定）：
 *  1. 时间一律是 ISO8601 **本地**字符串，不能 `toISOString()`（那是 UTC，会差一个时区且与旧数据不可比）；
 *  2. 布尔一律 INTEGER 0/1；
 *  3. `pomodoro_settings` 是 `id = 1` 的单行表，可能整行缺失。
 *
 * 查询全部走 `db.executeSync(...)`：`op-sqlite` 的 `execute` 是异步的，
 * 在同步上下文里会得到 `undefined`，之前已经踩过一次。
 */

import {
  DEFAULT_POMODORO_SETTINGS,
  type PomodoroMode,
  type PomodoroSettings,
} from '../core/pomodoro';
import type { DB } from './index';

/**
 * 当前时刻的 ISO8601 **本地**时间字符串：`YYYY-MM-DDTHH:MM:SS.mmm`。
 *
 * 不自己引第三方库、也不用 `toISOString()`：后者会把本地时间转成 UTC 再拼串，
 * 写进库里和 Flutter 版的历史数据差 8 小时，任何按日期切片的统计都会错位。
 *
 * ## 为什么小数部分是 3 位而不是 Dart 常见的 6 位（重要，别顺手「修」成 6 位）
 *
 * Dart `DateTime.toIso8601String()` 的规则是：**微秒部分为 0 时输出 3 位毫秒，非 0 时输出 6 位微秒**。
 * 实测（`dart.exe`）：
 *   - `DateTime.now()`                      → `2026-10-20T12:05:42.210140`（6 位）
 *   - `DateTime(2026,10,20,9,30,0)`         → `2026-10-20T09:30:00.000`（3 位）
 *   - `DateTime(2026,10,20,9,30,0,123)`     → `2026-10-20T09:30:00.123`（3 位）
 *   - `DateTime(2026,10,20,9,30,0,123,456)` → `2026-10-20T09:30:00.123456`（6 位）
 * 真机上 `DateTime.now()` 带微秒精度，所以**真实历史数据绝大多数落在 6 位那一支**。
 *
 * JS 的 `Date` 只有毫秒精度，**拿不到真实微秒**，因此无法复现 Dart 的分支选择：
 *   - 补随机微秒 → 数据不可复现，也无法用 equality 做任何校验；
 *   - 补固定 `.000` → 所有 RN 写入都会落在 3 位分支，与真实数据的 6 位分布不一致，等于用假分布掩盖差异。
 * 两者都比「诚实写 3 位」更糟，所以这里统一输出 3 位毫秒。
 *
 * **对兼容性的影响（下游必须知道）**：
 *   - 排序 / 区间过滤 / `LIKE` 前缀校验一律正确 —— 小数部分按字典序比较等价于按数值比较
 *     （`...00.123` < `...00.123456` < `...01.000`，与真实先后一致）；
 *   - 但**按字符串严格相等**去比对新旧数据（例如拿 `start_time` 当幂等键、或断言某行未被改写）**会失败**：
 *     RN 写的行永远是 3 位，Flutter 写的行可能是 6 位。
 *     需要判断「同一时刻」请比到秒（`SUBSTR(col, 1, 19)`）或转数值，不要直接 `=`。
 *
 * 同一段说明已同步到 docs/migration/schema-v3.md §1「时间」行。
 */
export function nowLocalIso(date: Date = new Date()): string {
  const pad = (value: number, length: number): string => String(value).padStart(length, '0');
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1, 2)}-${pad(date.getDate(), 2)}` +
    `T${pad(date.getHours(), 2)}:${pad(date.getMinutes(), 2)}:${pad(date.getSeconds(), 2)}` +
    `.${pad(date.getMilliseconds(), 3)}`
  );
}

/**
 * 读 `pomodoro_settings WHERE id = 1`，返回**分钟**单位的 camelCase 结构（可直接喂给 `durationSeconds`）。
 *
 * 兜底策略是逐字段的：任何一个字段为 NULL 就用该字段的默认值，
 * 而不是整行作废——用户可能只改过其中一项。
 *
 * 整表缺失 / SQL 出错时返回全量默认值并打日志：这是一张 `CHECK (id = 1)` 的单行表，
 * 不在金样本验收的 12 张表清单里，缺失是常态，绝不能让面板崩在启动阶段。
 */
export function readSettings(db: DB): PomodoroSettings {
  try {
    const res = db.executeSync(
      `SELECT work_duration, short_break_duration, long_break_duration, long_break_interval
         FROM pomodoro_settings WHERE id = 1`,
    );
    const row = (
      res.rows as Array<{
        work_duration: number | null;
        short_break_duration: number | null;
        long_break_duration: number | null;
        long_break_interval: number | null;
      }>
    )[0];

    if (!row) return { ...DEFAULT_POMODORO_SETTINGS };

    return {
      workDuration: row.work_duration ?? DEFAULT_POMODORO_SETTINGS.workDuration,
      shortBreakDuration: row.short_break_duration ?? DEFAULT_POMODORO_SETTINGS.shortBreakDuration,
      longBreakDuration: row.long_break_duration ?? DEFAULT_POMODORO_SETTINGS.longBreakDuration,
      longBreakInterval: row.long_break_interval ?? DEFAULT_POMODORO_SETTINGS.longBreakInterval,
    };
  } catch (e) {
    console.log('POMODORO_SETTINGS_FALLBACK', String(e));
    return { ...DEFAULT_POMODORO_SETTINGS };
  }
}

export type PomodoroRecordInput = {
  mode: PomodoroMode;
  /** 计划时长（秒） */
  durationSeconds: number;
  /** 实际时长（秒） */
  actualSeconds: number;
  /** 开始时间，ISO8601 本地字符串 */
  startTime: string;
  /** 结束时间；中断场景允许为 null（列本身可空） */
  endTime: string | null;
  isCompleted: boolean;
  /** 本次 Spike 不涉及任务关联，默认 NULL */
  relatedTaskId?: number | null;
  relatedTaskTitle?: string | null;
};

/**
 * 写一条番茄钟记录。
 *
 * 用参数化语句而不是字符串拼接：`related_task_title` 是快照标题，将来会塞进任意用户输入。
 * 未关联的字段显式写 NULL，而不是省掉列——省列会落到 DEFAULT，和 NULL 语义不同。
 */
export function insertRecord(db: DB, input: PomodoroRecordInput): void {
  db.executeSync(
    `INSERT INTO pomodoro_records
       (mode, duration_seconds, actual_seconds, start_time, end_time,
        related_task_id, related_task_title, is_completed, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      input.mode,
      Math.max(0, Math.round(input.durationSeconds)),
      Math.max(0, Math.round(input.actualSeconds)),
      input.startTime,
      input.endTime,
      input.relatedTaskId ?? null,
      input.relatedTaskTitle ?? null,
      input.isCompleted ? 1 : 0,
      nowLocalIso(),
    ],
  );
}

/** 记录总数，用来在面板上确认「确实写进去了」。 */
export function countRecords(db: DB): number {
  const res = db.executeSync('SELECT COUNT(*) AS c FROM pomodoro_records');
  return ((res.rows as Array<{ c: number }>)[0]?.c) ?? 0;
}
