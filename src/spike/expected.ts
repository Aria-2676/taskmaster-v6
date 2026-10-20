/**
 * 金样本期望值（由 fixtures/golden-v3.expected.json 生成，勿手改）。
 * 设备上读不到仓库文件，所以把期望值编进包里。
 */
import type { Expected } from './verifyGolden';

export const GOLDEN_EXPECTED: Expected = {
  "schemaVersion": 3,
  "counts": {
    "tasks": 10,
    "recycled_tasks": 2,
    "tags": 3,
    "task_tags": 4,
    "points_records": 6,
    "shop_items": 2,
    "purchased_items": 1,
    "pomodoro_records": 3,
    "custom_prize_pool": 3,
    "lottery_records": 1,
    "scratch_tickets": 3,
    "settings": 12
  },
  "balance": 250,
  "ledgerSum": 250,
  "orphanTaskTags": 0,
  "orphanTagRefs": 1,
  "nullScratchTickets": 1
};
