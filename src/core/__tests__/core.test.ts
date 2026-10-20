/**
 * 纯逻辑自测（无需设备、无需 RN 依赖）
 *
 * 运行：
 *   node --experimental-strip-types rn/src/core/__tests__/core.test.ts
 *
 * 覆盖：积分结算 / 循环任务日期生成 / OTA 清单版本判定。
 * 这些是「写错就会静默产生脏数据」的部分，必须能在没有手机的情况下回归。
 */

import assert from 'node:assert/strict';
import {
  resolveCompletion,
  resolveUncompletion,
  resolveOverdueDeduction,
  isOverdue,
} from '../points.ts';
import {
  generateInstanceDates,
  pickNewDates,
  instanceKey,
  generateLoopId,
} from '../recurrence.ts';
import {
  compareVersion,
  isBundleApplicable,
  candidateUrls,
  type OtaManifest,
} from '../../ota/manifest.ts';
import {
  DEFAULT_POMODORO_SETTINGS,
  durationSeconds,
  formatRemaining,
  nextMode,
  remainingSeconds,
  type PomodoroSettings,
} from '../pomodoro.ts';

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

const d = (y: number, m: number, day: number, h = 0, min = 0) => new Date(y, m - 1, day, h, min);
const fmt = (dt: Date) =>
  `${dt.getFullYear()}-${`${dt.getMonth() + 1}`.padStart(2, '0')}-${`${dt.getDate()}`.padStart(2, '0')}`;

/* ------------------------------ 积分结算 ------------------------------ */

test('完成任务：无历史流水 → 加分', () => {
  assert.deepEqual(resolveCompletion({ rewardPoints: 10, latestSettlementType: null }), {
    action: 'award',
    points: 10,
  });
});

test('完成任务：最近一条已是 task_complete → 不重复加分', () => {
  assert.equal(
    resolveCompletion({ rewardPoints: 10, latestSettlementType: 'task_complete' }).action,
    'none',
  );
});

test('完成任务：取消过之后可以再次加分', () => {
  assert.deepEqual(
    resolveCompletion({ rewardPoints: 10, latestSettlementType: 'task_uncomplete' }),
    { action: 'award', points: 10 },
  );
});

test('完成任务：rewardPoints = 0 → 不结算', () => {
  assert.equal(
    resolveCompletion({ rewardPoints: 0, latestSettlementType: null }).action,
    'none',
  );
});

test('取消完成：冲销金额取历史流水，而不是当前 rewardPoints', () => {
  const result = resolveUncompletion({
    latestSettlementType: 'task_complete',
    latestSettlementPoints: 20,
  });
  assert.deepEqual(result, { action: 'reverse', points: 20 });
  // 任务当前奖励改成 5 也不影响：参数里根本没有 rewardPoints
});

test('取消完成：最近一条不是加分 → 不冲销', () => {
  assert.equal(
    resolveUncompletion({ latestSettlementType: 'task_uncomplete', latestSettlementPoints: 20 })
      .action,
    'none',
  );
});

test('逾期扣分：15 分 → 扣 7（向下取整）', () => {
  assert.deepEqual(
    resolveOverdueDeduction({
      isOK: false,
      isDeducted: false,
      rewardPoints: 15,
      hasOverdueRecord: false,
    }),
    { action: 'deduct', points: 7 },
  );
});

test('逾期扣分：1 分 → 取整为 0，不扣', () => {
  assert.equal(
    resolveOverdueDeduction({
      isOK: false,
      isDeducted: false,
      rewardPoints: 1,
      hasOverdueRecord: false,
    }).action,
    'none',
  );
});

test('逾期扣分：已标记 is_deducted → 跳过', () => {
  assert.equal(
    resolveOverdueDeduction({
      isOK: false,
      isDeducted: true,
      rewardPoints: 20,
      hasOverdueRecord: false,
    }).action,
    'none',
  );
});

test('逾期扣分：已有扣分流水 → 跳过（即使标记丢了）', () => {
  assert.equal(
    resolveOverdueDeduction({
      isOK: false,
      isDeducted: false,
      rewardPoints: 20,
      hasOverdueRecord: true,
    }).action,
    'none',
  );
});

test('逾期判断：口径是「早于今天 00:00」，今天到期不算逾期', () => {
  // 今天到期 → 不算（今天 09:00 排期，今天 09:00 时判定）
  assert.equal(isOverdue(d(2026, 1, 31, 9), d(2026, 1, 31, 9)), false);
  // 今天到期但已过时刻 → **仍不算**。这是与旧口径的关键差异：
  // 旧口径（`cplTime < now`）在这里会判 true，导致今天到期当天就被扣分。
  assert.equal(isOverdue(d(2026, 1, 31, 0, 1), d(2026, 1, 31, 23, 59)), false);
  // 昨天到期 → 算逾期（这是 `cpl_time < 今天00:00` 的核心场景）
  assert.equal(isOverdue(d(2026, 1, 30, 23, 59), d(2026, 1, 31, 0, 1)), true);
  // 边界：恰好今天 00:00 → 不算（口径是「早于」，不含等于）
  assert.equal(isOverdue(d(2026, 1, 31, 0, 0), d(2026, 1, 31, 0, 0)), false);
  // 边界：昨天 00:00 → 算
  assert.equal(isOverdue(d(2026, 1, 30, 0, 0), d(2026, 1, 31, 0, 0)), true);
  // 跨月边界：上个月最后一天 → 今天第一天的 00:00 时，算逾期
  assert.equal(isOverdue(d(2026, 1, 31, 23, 0), d(2026, 2, 1, 0, 0)), true);
});

/* ------------------------------ 循环任务 ------------------------------ */

test('daily：从模板日起逐日到 now+15（含边界）', () => {
  const dates = generateInstanceDates('daily', d(2026, 1, 31), d(2026, 1, 31));
  assert.equal(dates.length, 16); // 1/31 → 2/15
  assert.equal(fmt(dates[0]), '2026-01-31');
  assert.equal(fmt(dates[dates.length - 1]), '2026-02-15');
});

test('daily：模板很旧时会从旧日期回补（与 Flutter 行为一致）', () => {
  const dates = generateInstanceDates('daily', d(2026, 1, 1), d(2026, 1, 31));
  assert.equal(dates.length, 46); // 1/1 → 2/15
  assert.equal(fmt(dates[0]), '2026-01-01');
});

test('weekly：对齐同一星期几，每次 +7', () => {
  const dates = generateInstanceDates('weekly', d(2026, 1, 31), d(2026, 1, 31));
  assert.deepEqual(dates.map(fmt), ['2026-01-31', '2026-02-07', '2026-02-14']);
});

test('monthly：31 号在 2 月取月末', () => {
  const dates = generateInstanceDates('monthly', d(2026, 1, 31), d(2026, 2, 20));
  assert.deepEqual(dates.map(fmt), ['2026-01-31', '2026-02-28']);
});

test('monthly：跨年进位', () => {
  const dates = generateInstanceDates('monthly', d(2025, 12, 15), d(2026, 1, 10));
  assert.ok(dates.some((x) => fmt(x) === '2026-01-15'));
});

test('none：不生成任何实例', () => {
  assert.deepEqual(generateInstanceDates('none', d(2026, 1, 31), d(2026, 1, 31)), []);
});

test('去重键：同 loop_id + 同一天', () => {
  assert.equal(instanceKey('loop_1', d(2026, 1, 5)), 'loop_1@2026-01-05');
  assert.equal(instanceKey('loop_1', d(2026, 1, 5, 23, 59)), 'loop_1@2026-01-05');
});

test('去重：已存在的日期被过滤，候选内的重复也去掉', () => {
  const dates = [d(2026, 1, 31), d(2026, 1, 31), d(2026, 2, 1)];
  const existing = new Set(['loop_x@2026-02-01']);
  const picked = pickNewDates('loop_x', dates, (k) => existing.has(k));
  assert.deepEqual(picked.map(fmt), ['2026-01-31']);
});

test('loopId 格式：loop_<毫秒>_<0-9999>', () => {
  assert.equal(generateLoopId(d(2026, 1, 31, 12), () => 0.5), 'loop_1769832000000_5000');
});

/* ------------------------------ OTA 清单 ------------------------------ */

test('版本比较', () => {
  assert.equal(compareVersion('6.0.0', '5.5.26'), 1);
  assert.equal(compareVersion('5.5.26', '5.5.26'), 0);
  assert.equal(compareVersion('5.5.9', '5.5.10'), -1);
  assert.equal(compareVersion('6.0', '6.0.0'), 0);
});

const manifest = (over: Partial<OtaManifest['bundle']> = {}): OtaManifest => ({
  schemaVersion: 1,
  bundle: {
    version: '6.0.1',
    build: 5,
    minAppVersion: '6.0.0',
    downloads: { 'android-arm64-v8a': { url: 'https://x/a.jsbundle', sha256: 'a', sizeBytes: 1 } },
    ...over,
  },
});

test('bundle 不能装到低于 minAppVersion 的 App 上', () => {
  const r = isBundleApplicable(manifest(), '5.5.26', 0);
  assert.equal(r.ok, false);
});

test('bundle build 高于本地 → 可装', () => {
  assert.equal(isBundleApplicable(manifest(), '6.0.0', 4).ok, true);
});

test('bundle build 不高于本地 → 拒绝（避免「越更新越旧」）', () => {
  assert.equal(isBundleApplicable(manifest(), '6.0.0', 5).ok, false);
});

test('超过 maxAppVersion → 拒绝', () => {
  assert.equal(isBundleApplicable(manifest({ maxAppVersion: '6.0.9' }), '6.1.0', 1).ok, false);
});

test('多源候选去重且保序', () => {
  const urls = candidateUrls({
    url: 'https://a',
    mirrors: ['https://b', 'https://a'],
    sha256: 'x',
    sizeBytes: 1,
  });
  assert.deepEqual(urls, ['https://a', 'https://b']);
});

/* ------------------------------ 番茄钟 ------------------------------ */

const ps = (over: Partial<PomodoroSettings> = {}): PomodoroSettings => ({
  ...DEFAULT_POMODORO_SETTINGS,
  ...over,
});

test('番茄钟默认设置与 schema 默认值一致（25/5/15/4）', () => {
  assert.deepEqual(DEFAULT_POMODORO_SETTINGS, {
    workDuration: 25,
    shortBreakDuration: 5,
    longBreakDuration: 15,
    longBreakInterval: 4,
  });
});

test('时长换算：settings 是分钟，records 是秒', () => {
  assert.equal(durationSeconds('work', ps()), 25 * 60);
  assert.equal(durationSeconds('shortBreak', ps()), 5 * 60);
  assert.equal(durationSeconds('longBreak', ps()), 15 * 60);
});

test('时长换算：自定义分钟数生效', () => {
  assert.equal(durationSeconds('work', ps({ workDuration: 1 })), 60);
  assert.equal(durationSeconds('longBreak', ps({ longBreakDuration: 20 })), 1200);
});

test('时长换算：脏分钟数（0 / 负数 / NaN）回落到默认', () => {
  assert.equal(durationSeconds('work', ps({ workDuration: 0 })), 25 * 60);
  assert.equal(durationSeconds('work', ps({ workDuration: -10 })), 25 * 60);
  assert.equal(durationSeconds('work', ps({ workDuration: Number.NaN })), 25 * 60);
  assert.equal(durationSeconds('work', ps({ workDuration: 25.6 })), 25 * 60); // 向下取整分钟
});

test('nextMode：达到 interval 整数倍才进长休', () => {
  assert.equal(nextMode(4, ps()), 'longBreak');
  assert.equal(nextMode(8, ps()), 'longBreak');
  assert.equal(nextMode(3, ps()), 'shortBreak');
  assert.equal(nextMode(5, ps()), 'shortBreak');
});

test('nextMode：0 个专注不立刻进长休（0 是任意数的整数倍，必须特判）', () => {
  assert.equal(nextMode(0, ps()), 'shortBreak');
});

test('nextMode：非法计数按 0 处理', () => {
  assert.equal(nextMode(-1, ps()), 'shortBreak');
  assert.equal(nextMode(Number.NaN, ps()), 'shortBreak');
});

test('nextMode：interval=1 时每个专注后都是长休', () => {
  assert.equal(nextMode(1, ps({ longBreakInterval: 1 })), 'longBreak');
  assert.equal(nextMode(7, ps({ longBreakInterval: 1 })), 'longBreak');
});

test('nextMode：interval 为 0 / 负数时退化为短休（不让长休永远触发不了）', () => {
  assert.equal(nextMode(4, ps({ longBreakInterval: 0 })), 'shortBreak');
  assert.equal(nextMode(4, ps({ longBreakInterval: -2 })), 'shortBreak');
});

test('formatRemaining：mm:ss', () => {
  assert.equal(formatRemaining(1500), '25:00');
  assert.equal(formatRemaining(65), '01:05');
  assert.equal(formatRemaining(5), '00:05');
  assert.equal(formatRemaining(0), '00:00');
});

test('formatRemaining：负数按 0 处理', () => {
  assert.equal(formatRemaining(-1), '00:00');
  assert.equal(formatRemaining(-3600), '00:00');
});

test('formatRemaining：超过一小时按总分钟显示，不进位成 hh:mm:ss', () => {
  assert.equal(formatRemaining(3600), '60:00');
  assert.equal(formatRemaining(4500), '75:00');
  assert.equal(formatRemaining(36000), '600:00');
});

test('formatRemaining：小数向上取整，起始瞬间显示满值', () => {
  assert.equal(formatRemaining(1499.2), '25:00'); // 刚过 0.8 秒仍显示 25:00
  assert.equal(formatRemaining(0.4), '00:01');
  assert.equal(formatRemaining(Number.NaN), '00:00');
});

test('remainingSeconds：差值向上取整', () => {
  assert.equal(remainingSeconds(10_500, 0), 11);
  assert.equal(remainingSeconds(10_000, 0), 10);
  assert.equal(remainingSeconds(1500, 1499), 1);
  assert.equal(remainingSeconds(1500, 1500), 0);
});

test('remainingSeconds：已过期 clamp 到 0', () => {
  assert.equal(remainingSeconds(0, 10_000), 0);
  assert.equal(remainingSeconds(1000, 999_999), 0);
});

test('remainingSeconds：非法时间戳返回 0 而不是 NaN', () => {
  assert.equal(remainingSeconds(Number.NaN, 0), 0);
  assert.equal(remainingSeconds(0, Number.NaN), 0);
});

/* ------------------------------ 结果 ------------------------------ */

console.log('');
console.log(`passed=${passed} failed=${failures.length}`);
if (failures.length > 0) {
  console.log('RESULT=FAIL');
  process.exitCode = 1;
} else {
  console.log('RESULT=PASS');
}
