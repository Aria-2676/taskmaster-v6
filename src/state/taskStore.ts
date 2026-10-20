/**
 * 任务状态。
 *
 * 本 store 只做「调仓储 + 刷新缓存」，业务规则一律在 `src/repo/taskRepo.ts` 里
 * （五键排序、重复检测、结算幂等、循环实例生成窗口、逾期的四条件）。
 *
 * ── 本文件额外负责的三件事（仓储不管、界面也不该管）──
 *
 * 1. **循环实例生成的触发时机**（spec §4.1）：创建循环任务、编辑循环任务后要
 *    跑 `generateRecurringTasks()`。仓储的 `addTask` / `updateTask` 内部**没有**
 *    这一步（Flutter 侧也是 Provider 里调的），放在 store 里才能让界面只写
 *    `addTask(...)` 就拿到完整行为。
 *    ⚠️ 完成时**不**生成（spec §3.2 明确写了，别自作聪明加进去）。
 *    ⚠️ 生成前会把模板日期夹到今天，见 `generateInstancesFor` 的注释
 *    —— 那是契约点名要处理的「回补几十条过期实例」。
 * 2. **任务→标签的写入**：`addTask` / `editTask` 收到 `tagIds` 时调
 *    `tagRepo.setTagsForTask()`。顺序照搬 spec §3.1（先写任务再写标签）与
 *    §3.4 入口 3（**先写标签再更新任务**）。两条都不在同一事务里——照搬 Flutter。
 * 3. **积分刷新的通知**：完成 / 取消完成 / 逾期扣分都会动余额，
 *    写操作成功后顺手刷 `usePointsStore`，界面不必自己记「什么时候该刷新积分」。
 *
 * ⚠️ **`task_tags` 的清理不在这里**：永久删除的清理只有
 * `recycleRepo` 那一份实现（V6 三步）。本 store 从不碰 `task_tags` 的删除，
 * 连 `removeTask` 都只是把行搬进回收站（V6 三步第 1 步的守卫在仓储内）。
 */

import { create } from 'zustand';
import { isoMinute, toBool } from '../repo/base';
import * as taskRepo from '../repo/taskRepo';
import * as tagRepo from '../repo/tagRepo';
import { usePointsStore } from './pointsStore';
import { fail, messageOf, normalizeDescription, ok } from './ops';
import type { EditTaskInput, NewTaskInput, OpResult, TaskStoreState } from './contracts';
import type { TaskRow } from '../repo/types';

/**
 * 把模板的 `cpl_time` 夹到「不早于今天 00:00」，**只改副本**。
 *
 * ⚠️ 刻意不写回库：库里那行的 `cpl_time` 是用户的原始排期，改了它，
 * 「这个任务本来是几号做的」这条信息就永久丢了。
 *
 * @param row 从库里读出的原行（不会有 `cpl_time` 为 null 的情况，列是 NOT NULL）
 */
function clampCplTimeToToday(row: TaskRow): TaskRow {
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  // 历史数据里 `cpl_time` 也可能用空格分隔（Dart 的 toIso8601String 之外还有
  // 手工拼接的来源），统一换成 'T' 再交给 Date 解析。
  const cpl = new Date(row.cpl_time.replace(' ', 'T'));
  if (cpl >= todayStart) return row;
  return { ...row, cpl_time: isoMinute(todayStart) };
}

export const useTaskStore = create<TaskStoreState>((set, get) => ({
  date: new Date(),
  tasks: [],
  loading: false,
  error: null,

  /**
   * 切换查看日期。顺带把该日期的任务读出来，避免界面只 `setDate` 忘了 `refresh`
   * 而看到上一天的数据。
   */
  setDate: (d: Date) => {
    set({ date: d, tasks: taskRepo.getTasksForDate(d), error: null });
  },

  /** 同步重读当前日期的任务。读操作是同步的（`getTasksForDate` 无 Promise）。 */
  refresh: () => {
    set({ tasks: taskRepo.getTasksForDate(get().date), error: null });
  },

  /**
   * 为一条循环任务模板补生成后续实例。
   *
   * ── 为什么要在这里「把 cpl_time 夹到今天」 ──────────────────────────
   * `generateRecurringTasks` 的窗口是「模板当天 00:00 → now+15 天」，
   * **起点没有下界**：模板日期很旧时会从旧日期逐日回补，凭空生成几十条历史实例。
   * 所以这里对「早于今天 00:00」的模板**只夹传给生成器的那一份副本**，
   * **不改动库里那行的原始 cpl_time**——用户的原始排期必须原样保留。
   *
   * 两个调用点的效果：
   * - 新建循环任务：模板日期是用户刚选的（今天或未来）→ 不触发夹取；
   * - 从回收站恢复三周前删掉的每日任务：夹到今天 → 只补今天起的 15 天，
   *   而不是回补出几十条过期实例（契约里点名的那个坑）。
   *
   * ⚠️ 非循环任务直接返回（`recurrence === 'none'`）——逾期 SQL 与生成器
   * 都排除它们，调了也是空转。
   */
  generateInstancesFor: async (taskId: number): Promise<void> => {
    const row = taskRepo.getTaskById(taskId);
    if (!row || row.recurrence === 'none') return;
    await taskRepo.generateRecurringTasks(clampCplTimeToToday(row));
  },

  addTask: async (input: NewTaskInput): Promise<OpResult> => {
    set({ loading: true, error: null });
    try {
      // `addTask` 是同步的（内部走 `executeSync` 的 INSERT）——不要加 await。
      const result = taskRepo.addTask({
        title: input.title.trim(),
        description: normalizeDescription(input.description),
        cpl_time: isoMinute(input.cplTime),
        is_word: input.isWord,
        recurrence: input.recurrence,
        reward_points: input.rewardPoints,
        priority: input.priority,
      });

      // ⚠️ 命中重复时 id 为 null 且**静默跳过**（spec §2.8）——不报错、不提示。
      // 这条路径上连标签也不写（spec §3.1 的 `createdTask.id != null` 判断）。
      if (result.id === null) {
        set({ loading: false });
        get().refresh();
        return ok();
      }

      if (input.tagIds !== undefined && input.tagIds.length > 0) {
        // ⚠️ `setTagsForTask` 返回 Promise，漏掉 await 时 tsc 不报错。
        await tagRepo.setTagsForTask(result.id, input.tagIds);
      }
      // 创建循环任务后立即补生成后续实例（spec §4.1）。
      await get().generateInstancesFor(result.id);

      set({ loading: false });
      get().refresh();
      return ok();
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return fail(e);
    }
  },

  editTask: async (input: EditTaskInput): Promise<OpResult> => {
    set({ loading: true, error: null });
    try {
      const existing = taskRepo.getTaskById(input.id);
      if (!existing) {
        set({ loading: false, error: '任务不存在' });
        return { ok: false, message: '任务不存在' };
      }

      // 先写标签，再更新任务（spec §3.4 入口 3：`_updateTask` 第一件事）。
      if (input.tagIds !== undefined) {
        await tagRepo.setTagsForTask(input.id, input.tagIds);
      }

      // ⚠️ 全列覆盖：`is_ok` / `completed_at` / `is_deducted` / `loop_id`
      // 必须从原行带过来，否则编辑会把「已完成」洗成「未完成」、
      // 把 `is_deducted` 置 0（= 逾期扣分的两道门同时失效）。
      // 反之 `created_at` **刻意不传**——让仓储取当前时间，照搬
      // spec §6.2 b 的既有行为（编辑会重置 `created_at`）。
      await taskRepo.updateTask(
        {
          id: input.id,
          title: input.title.trim(),
          description: normalizeDescription(input.description),
          cpl_time: isoMinute(input.cplTime),
          is_word: input.isWord,
          is_ok: toBool(existing.is_ok),
          recurrence: input.recurrence,
          completed_at: existing.completed_at,
          reward_points: input.rewardPoints,
          is_deducted: toBool(existing.is_deducted),
          loop_id: existing.loop_id,
          priority: input.priority,
        },
        input.updateAll ?? false,
      );

      // ⚠️ 编辑循环任务**无论改了哪个字段**都要重跑生成器（spec §4.1）。
      await get().generateInstancesFor(input.id);

      set({ loading: false });
      get().refresh();
      return ok();
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return fail(e);
    }
  },

  toggleComplete: async (id: number): Promise<OpResult> => {
    set({ loading: true, error: null });
    try {
      const task = taskRepo.getTaskById(id);
      if (!task) {
        set({ loading: false, error: '任务不存在' });
        return { ok: false, message: '任务不存在' };
      }

      // 两者都返回 Promise<number>：实际入账 / 扣回的积分（0 = 没动账）。
      // 积分联动在仓储内部完成，这里只负责把余额刷成新的。
      const delta =
        task.is_ok !== 0
          ? await taskRepo.uncompleteTask(id)
          : await taskRepo.completeTask(id);

      const completing = task.is_ok === 0;
      // 提示文案用**实际结算的金额**（`completeTask` / `uncompleteTask` 的返回值），
      // 不是任务当前的 `reward_points`——照搬 v5 的话这里会显示成
      // 「改过奖励值后取消完成」的错误金额（spec §6.2 c 记录的既有行为，这里是修）。
      // delta 为 0 表示没动账（奖励为 0、或已结算过），此时不提示。
      if (delta > 0) usePointsStore.getState().refresh();
      set({ loading: false });
      get().refresh();
      return ok(
        delta > 0
          ? completing
            ? `已完成，获得 +${delta} 积分`
            : `已取消完成，扣除 ${delta} 积分`
          : null,
      );
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return fail(e);
    }
  },

  /**
   * 移入回收站（软删除）。
   *
   * ⚠️ 走 `taskRepo.deleteTask(id)` 的 `deleteAll=false` 分支，它在内部委托
   * `recycleRepo.moveTaskToRecycleBin()`——回收站裁剪 + 标签关联清理
   * （V6 三步）都在那一份实现里，本 store 不重复实现。
   */
  removeTask: async (id: number): Promise<OpResult> => {
    set({ loading: true, error: null });
    try {
      await taskRepo.deleteTask(id);
      set({ loading: false });
      get().refresh();
      return ok();
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return fail(e);
    }
  },

  /**
   * 连同循环系列的后续实例一起**物理删除**（不进回收站、不可恢复）。
   *
   * 走 `taskRepo.deleteTask(id, true)` → `deleteRecurringInstances()`，
   * 它是 V6 三步的第四条路径、且与回收站三处的语句顺序**相反**
   * （先删 `tasks` 再清 `task_tags`）——只有仓储里那一份实现，这里不动 SQL。
   */
  removeAllInstances: async (id: number): Promise<OpResult> => {
    set({ loading: true, error: null });
    try {
      await taskRepo.deleteTask(id, /* deleteAll= */ true);
      set({ loading: false });
      get().refresh();
      return ok();
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return fail(e);
    }
  },

  /**
   * 冷启动时补扣逾期（spec §3.5）。
   *
   * ⚠️ 只在**应用冷启动**时调一次。**没有定时器、没有跨午夜重跑**——
   * App 挂后台跨过午夜不会扣分，必须冷启动。界面别拿它当定时任务。
   *
   * @returns 实际扣了分的任务条数
   */
  catchUpOverdue: async (): Promise<number> => {
    set({ loading: true, error: null });
    try {
      const deducted = await taskRepo.checkOverdueTasks();
      if (deducted > 0) usePointsStore.getState().refresh();
      set({ loading: false });
      get().refresh();
      return deducted;
    } catch (e) {
      set({ loading: false, error: messageOf(e) });
      return 0;
    }
  },
}));
