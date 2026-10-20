/**
 * 循环任务生成（纯函数）
 *
 * 对应 docs/migration/business-rules.md §2。
 * 与 Flutter 版保持一致的四条：
 * 1. 窗口 = now → now + 15 天（含边界日）；
 * 2. daily 逐日、weekly 对齐星期几后 +7、monthly 取「当月同日，超出则月末」；
 * 3. 去重键 = loop_id + 当天（不是标题）；
 * 4. 其它 recurrence 直接不生成。
 */

export type Recurrence = 'none' | 'daily' | 'weekly' | 'monthly';

export const RECURRENCE_WINDOW_DAYS = 15;

/** 去掉时分秒，得到当天 00:00（本地时区，与 Flutter 版一致）。 */
export function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

export function addDays(d: Date, days: number): Date {
  const next = new Date(d.getTime());
  next.setDate(next.getDate() + days);
  return startOfDay(next);
}

/** 当月天数。`month` 为 0-based，与 Date 一致。 */
export function daysInMonth(year: number, month: number): number {
  return new Date(year, month + 1, 0).getDate();
}

/**
 * 生成实例日期列表（不含「已存在」的那几天由调用方过滤）。
 *
 * @param cplTime 模板任务的计划完成时间
 * @param now     当前时间（决定窗口）
 */
export function generateInstanceDates(
  recurrence: Recurrence,
  cplTime: Date,
  now: Date,
  windowDays: number = RECURRENCE_WINDOW_DAYS,
): Date[] {
  if (recurrence === 'none') return [];

  const rangeEnd = addDays(startOfDay(now), windowDays);
  const dates: Date[] = [];

  if (recurrence === 'daily') {
    let next = startOfDay(cplTime);
    while (next.getTime() <= rangeEnd.getTime()) {
      dates.push(next);
      next = addDays(next, 1);
    }
    return dates;
  }

  if (recurrence === 'weekly') {
    let next = startOfDay(cplTime);
    const targetWeekday = startOfDay(cplTime).getDay();
    while (next.getDay() !== targetWeekday) {
      next = addDays(next, 1);
    }
    while (next.getTime() <= rangeEnd.getTime()) {
      dates.push(next);
      next = addDays(next, 7);
    }
    return dates;
  }

  // monthly：按模板的「日」取，当月没有该日则取月末
  const wantedDay = startOfDay(cplTime).getDate();
  let cursor = new Date(cplTime.getFullYear(), cplTime.getMonth(), 1);
  let guard = 0;
  while (cursor.getTime() <= rangeEnd.getTime() && guard < 240) {
    guard += 1;
    const maxDay = daysInMonth(cursor.getFullYear(), cursor.getMonth());
    const day = Math.min(wantedDay, maxDay);
    const candidate = new Date(cursor.getFullYear(), cursor.getMonth(), day);
    if (candidate.getTime() <= rangeEnd.getTime()) {
      dates.push(candidate);
    }
    cursor = new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1);
  }
  return dates;
}

/** 去重键：同 loop_id + 同一天。日期用 `YYYY-MM-DD` 表示，避免时区歧义。 */
export function instanceKey(loopId: string, date: Date): string {
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, '0');
  const d = `${date.getDate()}`.padStart(2, '0');
  return `${loopId}@${y}-${m}-${d}`;
}

/**
 * 过滤掉已存在的实例，返回真正要插入的日期。
 *
 * `exists` 由调用方提供（通常是一次 SQL 查询的结果集），保持本函数纯粹。
 */
export function pickNewDates(
  loopId: string,
  candidates: Date[],
  exists: (key: string) => boolean,
): Date[] {
  const seen = new Set<string>();
  return candidates.filter((date) => {
    const key = instanceKey(loopId, date);
    if (seen.has(key)) return false;
    seen.add(key);
    return !exists(key);
  });
}

/** loopId 生成：`loop_<毫秒>_<0-9999>`，与 Flutter 版同格式。 */
export function generateLoopId(now: Date = new Date(), random: () => number = Math.random): string {
  return `loop_${now.getTime()}_${Math.floor(random() * 10000)}`;
}
