/**
 * 积分结算规则（纯函数，无 DB / 无 UI）
 *
 * 对应 docs/migration/business-rules.md §1。
 * 这里只做「该不该结算、结算多少」的判定；写库由调用方在事务里完成。
 *
 * 之所以抽成纯函数：这是最容易写错、也最值得测的一块，
 * 不依赖原生模块就能在 Node 里跑。
 */

export type SettlementType = 'task_complete' | 'task_uncomplete' | 'overdue_deduct';

export type Settlement =
  | { action: 'award'; points: number }
  | { action: 'reverse'; points: number }
  | { action: 'deduct'; points: number }
  | { action: 'none'; reason: string };

/**
 * 完成任务。
 *
 * 规则：只有「最近一条结算流水不是 task_complete」才加分。
 * 也就是说取消过一次后可以再次加分，不会永久失效。
 */
export function resolveCompletion(input: {
  rewardPoints: number;
  latestSettlementType: SettlementType | null;
}): Settlement {
  if (input.rewardPoints <= 0) {
    return { action: 'none', reason: 'rewardPoints <= 0' };
  }
  if (input.latestSettlementType === 'task_complete') {
    return { action: 'none', reason: 'already awarded' };
  }
  return { action: 'award', points: input.rewardPoints };
}

/**
 * 取消完成。
 *
 * 规则：只有最近一条是 task_complete 才冲销，且金额取**那条流水**的 points，
 * 不是任务当前的 rewardPoints（完成期间改过奖励也要对称）。
 */
export function resolveUncompletion(input: {
  latestSettlementType: SettlementType | null;
  latestSettlementPoints: number | null;
}): Settlement {
  if (input.latestSettlementType !== 'task_complete') {
    return { action: 'none', reason: 'no award to reverse' };
  }
  const amount = Math.abs(input.latestSettlementPoints ?? 0);
  if (amount <= 0) {
    return { action: 'none', reason: 'zero award record' };
  }
  return { action: 'reverse', points: amount };
}

/**
 * 逾期扣分。
 *
 * 规则：`floor(rewardPoints / 2)`，为 0 不扣；已有 overdue_deduct 记录则跳过。
 * **顺序要求**：调用方必须先扣分成功，再置 is_deducted。
 */
export function resolveOverdueDeduction(input: {
  isOK: boolean;
  isDeducted: boolean;
  rewardPoints: number;
  hasOverdueRecord: boolean;
}): Settlement {
  if (input.isOK) return { action: 'none', reason: 'completed' };
  if (input.isDeducted) return { action: 'none', reason: 'already marked' };
  if (input.rewardPoints <= 0) return { action: 'none', reason: 'no reward' };
  if (input.hasOverdueRecord) return { action: 'none', reason: 'deduct record exists' };

  const points = Math.floor(input.rewardPoints / 2);
  if (points <= 0) return { action: 'none', reason: 'rounded to zero' };
  return { action: 'deduct', points };
}

/**
 * 判断任务是否逾期。
 *
 * **口径：`cpl_time` 早于「今天 00:00」才算逾期**——今天凌晨到现在的任务**不算**。
 * 这是以代码为准的结论（`docs/migration/spec-review.md` G2 已核实）：
 * Flutter 侧 `task_repository.dart:252` 的 `WHERE cpl_time < ?` 传入的是
 * `DateTime(年, 月, 日)`（当天零点），**没有 `+1 day`**。
 *
 * ⚠️ Dart 侧那个变量名叫 `endOfDay`，但它实际是**当天零点**而不是当天末尾——
 * 这是历史遗留的误导性命名，**不要按变量名理解**。
 *
 * 用 `now` 的时刻比较是错的：那样今天到期但未完成的任务会在当天被扣分，
 * 而 Flutter 侧要等到**次日冷启动**才扣。
 *
 * @param cplTime 任务排期时间
 * @param now     当前时间（用于取「今天」的日期边界）
 */
export function isOverdue(cplTime: Date, now: Date): boolean {
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0, 0);
  return cplTime.getTime() < todayStart.getTime();
}
