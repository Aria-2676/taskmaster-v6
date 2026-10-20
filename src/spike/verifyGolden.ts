/**
 * 金样本验收（Spike 第 1 项）
 *
 * 输入：fixtures/golden-v3.db（由 tool/make_golden_sample.py 生成）
 *      fixtures/golden-v3.expected.json（期望值）
 * 输出：逐项 PASS / FAIL，任一项 FAIL 就不要继续往下做。
 *
 * 为什么必须做：v6.0.0 不可回退。迁移读错字段，用户数据就错，且退不回来。
 */

import { countBadTimestamps, countOrphans, countRows, openDatabase, readBalance, closeDatabase } from '../db';

export type Expected = {
  schemaVersion: number;
  counts: Record<string, number>;
  balance: number;
  ledgerSum: number;
  orphanTaskTags: number;
  orphanTagRefs: number;
  nullScratchTickets: number;
};

export type CheckResult = { name: string; ok: boolean; detail: string };

const TABLES = [
  'tasks', 'recycled_tasks', 'tags', 'task_tags', 'points_records',
  'shop_items', 'purchased_items', 'pomodoro_records',
  'custom_prize_pool', 'lottery_records', 'scratch_tickets', 'settings',
];

export function verifyGolden(expected: Expected, dbPath?: string): CheckResult[] {
  const db = openDatabase(dbPath);
  const results: CheckResult[] = [];

  const mismatched: string[] = [];
  for (const table of TABLES) {
    const actual = countRows(db, table);
    const want = expected.counts[table];
    if (actual !== want) mismatched.push(`${table}: ${actual} != ${want}`);
  }
  results.push({
    name: '表行数一致',
    ok: mismatched.length === 0,
    detail: mismatched.length === 0 ? '12 张表全部一致' : mismatched.join('; '),
  });

  const { balance, ledgerSum } = readBalance(db);
  results.push({
    name: '余额 == 流水净额',
    ok: balance === ledgerSum && balance === expected.balance,
    detail: `balance=${balance}, ledger=${ledgerSum}, expected=${expected.balance}`,
  });

  const orphans = countOrphans(db);
  results.push({
    name: '孤儿关联与期望一致',
    ok:
      orphans.taskTags === expected.orphanTaskTags &&
      orphans.tagRefs === expected.orphanTagRefs,
    detail: `task_tags→tasks=${orphans.taskTags}, task_tags→tags=${orphans.tagRefs}`,
  });

  const badTime = countBadTimestamps(db);
  results.push({
    name: '时间格式抽样',
    ok: badTime === 0,
    detail: `异常行数=${badTime}`,
  });

  const integrity = db.executeSync('PRAGMA integrity_check');
  const integrityValue = (integrity.rows as Array<Record<string, unknown>>)[0];
  results.push({
    name: 'PRAGMA integrity_check',
    ok: JSON.stringify(integrityValue).includes('ok'),
    detail: JSON.stringify(integrityValue),
  });

  closeDatabase();
  return results;
}

export function formatReport(results: CheckResult[]): string {
  const lines = results.map((r) => `${r.ok ? 'PASS' : 'FAIL'}  ${r.name}  —  ${r.detail}`);
  const failed = results.filter((r) => !r.ok).length;
  lines.push('');
  lines.push(failed === 0 ? 'RESULT=PASS' : `RESULT=FAIL (${failed})`);
  return lines.join('\n');
}
