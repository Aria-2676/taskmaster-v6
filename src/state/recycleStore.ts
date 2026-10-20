/**
 * 回收站状态。
 *
 * 🔴 **本 store 绝不自己写 `task_tags` 的清理 SQL。**
 *
 * 永久删除的清理有且只有 `src/repo/recycleRepo.ts` 那一份实现，里面是
 * **V6 三步**：
 *   1. 条件用 `task_id`，**永远不用 `recycled_tasks.id`**；
 *   2. `task_id` 取自本次真正被删的那几行；
 *   3. 附 `NOT IN (SELECT id FROM tasks)` 守卫。
 * 第 3 步漏掉时**不会有任何报错**，只会静默删掉仍然活着的任务的标签关联
 * （金样本里 `recycled_tasks.id=1` 与 `task_id=5` 并存，而 `tasks` 里 id=5 是活的），
 * 且孤儿数断言照样是 0、发现不了。所以这里只调 `permanentDelete` / `clearRecycleBin`。
 *
 * ── 保留策略（界面文案必须照实说）─────────────────────────────────────
 * 只保留**最近 10 条**（`RECYCLE_BIN_LIMIT`），**无时间过期**；
 * 删第 11 个时最旧的那个**立即**被物理删除。
 * 不要写「删除的任务会保留一段时间」（那是 Flutter 版误导的原话）。
 */

import { create } from 'zustand';
import * as recycleRepo from '../repo/recycleRepo';
import { useTaskStore } from './taskStore';
import { fail, ok } from './ops';
import type { OpResult, RecycleStoreState } from './contracts';

export const useRecycleStore = create<RecycleStoreState>((set, get) => ({
  items: [],

  /** 同步重读回收站（`deleted_at DESC`，最近删除的在前）。 */
  refresh: () => {
    set({ items: recycleRepo.getRecycledTasks() });
  },

  /**
   * 恢复整条。
   *
   * ⚠️ 循环任务恢复后要触发生成（spec §4.1 第四行），但**必须经
   * `useTaskStore.generateInstancesFor()`**——它内部会把模板日期夹到今天。
   * 直接调 `generateRecurringTasks` 的话，删掉三周前的每日任务再恢复会
   * 补出几十条过期实例（契约点名的坑，也是 spec H3 记录的既有缺陷）。
   *
   * ⚠️ 仓储会把原 `task_id` 写回（H1），本 store 不做任何引用改写。
   */
  restore: async (recycledTaskId: number): Promise<OpResult> => {
    try {
      const restored = await recycleRepo.restoreTaskFromRecycle(recycledTaskId);
      await useTaskStore.getState().generateInstancesFor(restored.taskId);
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  /**
   * 只恢复单个实例（保持原始日期、关闭循环）。
   *
   * ⚠️ 与 `restore` 的差异不是「恢复到今天」——Flutter 版按钮叫「仅恢复当天」
   * 但行为是后者，属文案与实际不符（spec D.5）。这里不触发生成。
   */
  restoreSingle: async (recycledTaskId: number): Promise<OpResult> => {
    try {
      await recycleRepo.restoreSingleInstance(recycledTaskId);
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  /**
   * 永久删除单条（不进回收站、不可恢复）。
   *
   * ⚠️ 不退还积分：**不动** `points_records`、也**不动** `user_points`
   * （spec D.7）——否则「删任务 → 清回收站」就能刷分。
   * 本 store 里没有任何积分相关调用就是因为这个。
   */
  permanentDelete: async (recycledTaskId: number): Promise<OpResult> => {
    try {
      await recycleRepo.permanentDelete(recycledTaskId);
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  clearAll: async (): Promise<OpResult> => {
    try {
      await recycleRepo.clearRecycleBin();
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },
}));
