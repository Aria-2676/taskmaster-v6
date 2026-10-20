/**
 * 积分状态。
 *
 * 本 store **只读**：积分的写入全部由 `taskRepo`（完成 / 取消完成 / 逾期扣分）
 * 与 `shopRepo`（兑换）在各自的事务里完成，这里不提供任何写方法。
 * 把「加分」暴露成 store 方法会让 `balance == SUM(流水)` 这条不变量
 * 多一个破坏口（schema-v3 §7 第 2 条）。
 *
 * ⚠️ 刷新来源：完成任务 / 兑换商品都会改余额，那两条路径由
 * `taskStore` / `shopStore` 主动调 `usePointsStore.getState().refresh()`。
 * 界面不必也不该自己去记「什么时候该刷新积分」。
 */

import { create } from 'zustand';
import * as pointsRepo from '../repo/pointsRepo';
import type { PointsStoreState } from './contracts';

export const usePointsStore = create<PointsStoreState>(set => ({
  balance: 0,
  records: [],
  invariantOk: true,

  /**
   * 同步重读。读操作本身是同步的（op-sqlite 的 `executeSync`），不要改成 async。
   *
   * ⚠️ `balance` 取自 `checkBalanceInvariant()` 的返回值，不额外调 `getBalance()`：
   * 这样 `balance` 与 `invariantOk` 来自**同一次**读取，不会出现
   * 「余额读到了新的、流水净额还是旧的」而假报不一致。
   * `checkBalanceInvariant()` 返回的是
   * `{balance, ledgerSum, consistent}`，不是 boolean——契约里的
   * `invariantOk` 取其中的 `.consistent`。
   */
  refresh: () => {
    const invariant = pointsRepo.checkBalanceInvariant();
    set({
      balance: invariant.balance,
      records: pointsRepo.getPointsRecords(),
      invariantOk: invariant.consistent,
    });
  },
}));
