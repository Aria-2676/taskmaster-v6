/**
 * 积分 / 商城 / 标签 / 回收站「纯逻辑」自测（无需设备、无需 RN 依赖）
 *
 * 运行（仓库根 rn/ 下）：
 *   node --experimental-strip-types src/core/__tests__/pointsShop.test.ts
 *
 * 覆盖 `core/pointsRules.ts` 的全部导出：七种 type 的文案/图标/符号、
 * 金额正负口径、明细排序、标签颜色解析、仓库按 name 分组。
 * 这些是「写错会静默产生脏数据或用户看不懂的界面」的部分，必须能在没有手机的情况下回归。
 *
 * 仓储层（`repo/*.ts`）**不在此覆盖**——它依赖 op-sqlite 原生模块，
 * 只能在真机 / 模拟器上验证，由 QA 阶段负责。
 */

import assert from 'node:assert/strict';
import {
  POINTS_RECORD_TYPES,
  POINTS_TYPE_META,
  POINTS_RECORD_LIMIT,
  UNKNOWN_TYPE_META,
  typeMeta,
  typeLabel,
  typeIcon,
  isIncome,
  signPrefix,
  formatAmount,
  comparePointsRecords,
  parseTagColorArgb,
  FALLBACK_TAG_COLOR_ARGB,
  DEFAULT_TAG_COLOR,
  TAG_COLOR_PALETTE,
  groupPurchasedByName,
  pickOldestForUse,
} from '../pointsRules.ts';

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

/* ── 七种 type ──────────────────────────────────────────────────────── */

test('流水类型恰好 7 种（spec G1：文档漏了 shop_purchase / scratch_cost）', () => {
  assert.equal(POINTS_RECORD_TYPES.length, 7);
  assert.deepEqual(
    [...POINTS_RECORD_TYPES].sort(),
    [
      'overdue_deduct',
      'scratch_cost',
      'scratch_refund',
      'scratch_win',
      'shop_purchase',
      'task_complete',
      'task_uncomplete',
    ],
  );
});

test('七种 type 各自的中文文案', () => {
  assert.equal(typeLabel('task_complete'), '完成任务');
  assert.equal(typeLabel('task_uncomplete'), '取消完成');
  assert.equal(typeLabel('overdue_deduct'), '逾期扣分');
  assert.equal(typeLabel('shop_purchase'), '商城兑换');
  assert.equal(typeLabel('scratch_cost'), '购买刮刮卡');
  assert.equal(typeLabel('scratch_win'), '刮奖中奖');
  assert.equal(typeLabel('scratch_refund'), '刮奖退款');
});

test('七种 type 各自的图标名（沿用 Flutter Material 图标名）', () => {
  assert.equal(typeIcon('task_complete'), 'check_circle');
  assert.equal(typeIcon('task_uncomplete'), 'cancel');
  assert.equal(typeIcon('overdue_deduct'), 'warning');
  assert.equal(typeIcon('shop_purchase'), 'shopping_bag');
  assert.equal(typeIcon('scratch_cost'), 'casino');
  assert.equal(typeIcon('scratch_win'), 'celebration');
  assert.equal(typeIcon('scratch_refund'), 'refresh');
});

test('七种 type 各自的正负号（3 种收入 / 4 种支出）', () => {
  assert.equal(POINTS_TYPE_META.task_complete.sign, 1);
  assert.equal(POINTS_TYPE_META.scratch_win.sign, 1);
  assert.equal(POINTS_TYPE_META.scratch_refund.sign, 1);
  assert.equal(POINTS_TYPE_META.task_uncomplete.sign, -1);
  assert.equal(POINTS_TYPE_META.overdue_deduct.sign, -1);
  assert.equal(POINTS_TYPE_META.shop_purchase.sign, -1);
  assert.equal(POINTS_TYPE_META.scratch_cost.sign, -1);
});

test('未知 type 走兜底，不抛异常（老库升级后可能有未知取值）', () => {
  assert.deepEqual(typeMeta('some_future_type'), UNKNOWN_TYPE_META);
  assert.equal(typeIcon('some_future_type'), 'swap_horiz');
  assert.equal(typeLabel('some_future_type'), '积分变动');
  assert.equal(typeMeta('').label, '积分变动');
});

/* ── 金额正负 ────────────────────────────────────────────────────────── */

test('isIncome：points > 0 即收入，0 与负数都不是（照搬 Flutter 的 points > 0）', () => {
  assert.equal(isIncome(10), true);
  assert.equal(isIncome(1), true);
  assert.equal(isIncome(0), false);
  assert.equal(isIncome(-10), false);
});

test('formatAmount：正数补 +，负数保留负号，0 就是 0', () => {
  assert.equal(formatAmount(10), '+10');
  assert.equal(formatAmount(1), '+1');
  assert.equal(formatAmount(-10), '-10');
  assert.equal(formatAmount(-1), '-1');
  assert.equal(formatAmount(0), '0');
});

test('formatAmount：绝不对负数取绝对值（否则支出会被显示成收入）', () => {
  assert.ok(formatAmount(-50).startsWith('-'), '-50 必须保留负号');
  assert.ok(!formatAmount(-50).startsWith('+'), '-50 不能带 + 号');
});

test('signPrefix：只有收入带 + 前缀', () => {
  assert.equal(signPrefix(10), '+');
  assert.equal(signPrefix(-10), '');
  assert.equal(signPrefix(0), '');
});

/* ── 明细排序 ────────────────────────────────────────────────────────── */

test('明细列表上限 50 条（spec A.8 / F20：无分页、无汇总）', () => {
  assert.equal(POINTS_RECORD_LIMIT, 50);
});

test('排序：created_at 倒序（最近的在前）', () => {
  const rows = [
    { id: 1, created_at: '2026-10-20T09:00:00.000' },
    { id: 3, created_at: '2026-10-20T11:00:00.000' },
    { id: 2, created_at: '2026-10-20T10:00:00.000' },
  ];
  const sorted = [...rows].sort(comparePointsRecords);
  assert.deepEqual(
    sorted.map(r => r.id),
    [3, 2, 1],
  );
});

test('排序：created_at 相同时按 id 倒序兜底，保证顺序稳定不跳动', () => {
  const same = '2026-10-20T09:00:00.000';
  const sorted = [
    { id: 1, created_at: same },
    { id: 2, created_at: same },
    { id: 3, created_at: same },
  ].sort(comparePointsRecords);
  assert.deepEqual(
    sorted.map(r => r.id),
    [3, 2, 1],
  );
});

test('排序：3 位与 6 位小数的时间戳仍能正确比较（字典序 == 时间序）', () => {
  const sorted = [
    { id: 1, created_at: '2026-10-20T09:00:00.123' },
    { id: 2, created_at: '2026-10-20T09:00:00.123456' },
    { id: 3, created_at: '2026-10-20T09:00:00.000' },
  ].sort(comparePointsRecords);
  // '.000' < '.123' < '.123456'
  assert.deepEqual(
    sorted.map(r => r.id),
    [2, 1, 3],
  );
});

/* ── 标签颜色 ────────────────────────────────────────────────────────── */

test("标签颜色 '#2196F3' → 带 FF alpha 的 ARGB", () => {
  assert.equal(parseTagColorArgb('#2196F3'), 0xff2196f3);
  assert.equal(parseTagColorArgb('#FF9800'), 0xffff9800);
  assert.equal(parseTagColorArgb('#4CAF50'), 0xff4caf50);
});

test('标签颜色：大小写十六进制都能解析', () => {
  assert.equal(parseTagColorArgb('#abcdef'), parseTagColorArgb('#ABCDEF'));
});

test('标签颜色：省略 # 也能解析（与 Flutter replaceFirst("#","") 行为一致）', () => {
  assert.equal(parseTagColorArgb('2196F3'), 0xff2196f3);
});

test('标签颜色：非十六进制字符 → 静默兜底为蓝色（不抛异常）', () => {
  for (const bad of ['#GGGGGG', 'not-a-color', '#12345', '', '#']) {
    assert.equal(parseTagColorArgb(bad), FALLBACK_TAG_COLOR_ARGB, `输入：${bad}`);
  }
});

test('标签颜色：8 位 #AARRGGBB 静默降级为蓝色【已知现象】', () => {
  // 拼上 FF 后是 10 位十六进制，超出 ARGB 的 32 位表示范围 → 判为非法 → 兜底蓝色。
  // spec C.2 把原因写成「int.parse 抛异常」并不准确（10 位十六进制是合法数字，
  // 能解析成功，只是结果溢出 32 位），但**行为**——降级为蓝色——一致。
  assert.equal(parseTagColorArgb('#802196F3'), FALLBACK_TAG_COLOR_ARGB);
  assert.equal(parseTagColorArgb('#FF2196F3'), FALLBACK_TAG_COLOR_ARGB);
});

test('兜底蓝色恰好等于默认色（Flutter Colors.blue = Material Blue 500）', () => {
  assert.equal(FALLBACK_TAG_COLOR_ARGB, 0xff2196f3);
  assert.equal(DEFAULT_TAG_COLOR, '#2196F3');
  assert.equal(parseTagColorArgb(DEFAULT_TAG_COLOR), FALLBACK_TAG_COLOR_ARGB);
});

test('色板 16 色，且默认色在色板内', () => {
  assert.equal(TAG_COLOR_PALETTE.length, 16);
  assert.ok(TAG_COLOR_PALETTE.includes(DEFAULT_TAG_COLOR));
  // 色板内每一色都必须能被正常解析（即都符合 #RRGGBB 形状，不会被误判成非法值）。
  // 注意不能断言「解析结果 != 兜底蓝」——默认色 #2196F3 的解析结果恰好**就是**兜底蓝。
  for (const color of TAG_COLOR_PALETTE) {
    assert.match(color, /^#[0-9A-F]{6}$/, `色板色格式非法：${color}`);
    assert.equal(parseTagColorArgb(color), parseInt(`FF${color.slice(1)}`, 16));
  }
});

/* ── 仓库按 name 分组 ────────────────────────────────────────────────── */

interface Row {
  id: number;
  name: string;
}

test('仓库分组：同名合并成一组', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 1, name: '买一本书' },
    { id: 2, name: '买一本书' },
    { id: 3, name: '休息15分钟' },
  ]);
  assert.equal(groups.length, 2);
  const books = groups.find(g => g.name === '买一本书');
  assert.equal(books?.count, 2);
  assert.deepEqual(
    books?.items.map(i => i.id),
    [1, 2],
  );
});

test('仓库分组：组顺序 = 首次出现顺序（即按最近兑换时间倒序）', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 1, name: 'B' },
    { id: 2, name: 'A' },
    { id: 3, name: 'B' },
  ]);
  assert.deepEqual(
    groups.map(g => g.name),
    ['B', 'A'],
  );
});

test('仓库分组：商品改名 → 分裂成两组（即使 shop_item_id 相同，属既定行为）', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 1, name: '旧名字' },
    { id: 2, name: '新名字' },
  ]);
  assert.equal(groups.length, 2, '改名后快照 name 不同，必须分成两组');
});

test('仓库分组：不同 id 但重名 → 合并成一组（name 无 UNIQUE 约束）', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 1, name: '重名' },
    { id: 2, name: '重名' },
  ]);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].count, 2);
});

test('仓库分组：latest = 最新那条，oldest = 最旧那条（列表已按 purchased_at DESC）', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 10, name: 'X' },
    { id: 11, name: 'X' },
    { id: 12, name: 'X' },
  ]);
  assert.equal(groups[0].latest.id, 10, 'latest 应为最新（列表首条）');
  assert.equal(groups[0].oldest.id, 12, 'oldest 应为最旧（列表末条）');
});

test('「使用」删的是 oldest（最旧），与显示的 latest 不是同一条', () => {
  const groups = groupPurchasedByName<Row>([
    { id: 10, name: 'X' },
    { id: 11, name: 'X' },
  ]);
  const g = groups[0];
  assert.equal(pickOldestForUse(g).id, 11, '「使用」应删最旧那条');
  assert.notEqual(pickOldestForUse(g).id, g.latest.id, '删除的记录不能是显示的那条');
});

test('仓库分组：空列表返回空数组（不抛异常）', () => {
  assert.deepEqual(groupPurchasedByName<Row>([]), []);
});

test('仓库分组：单条时 latest 与 oldest 是同一条', () => {
  const groups = groupPurchasedByName<Row>([{ id: 7, name: 'X' }]);
  assert.equal(groups[0].latest.id, 7);
  assert.equal(groups[0].oldest.id, 7);
  assert.equal(groups[0].count, 1);
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