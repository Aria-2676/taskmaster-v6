/**
 * 标签状态。
 *
 * ── 三条照搬的既有语义 ────────────────────────────────────────────────
 *
 * 1. **重名的两层语义不一致**：DB 的 `UNIQUE` 是 BINARY（大小写敏感），
 *    而界面层按小写比较 → 库里可以同时有 `Work` 和 `work`，
 *    但界面会以「已存在」拒绝创建（spec C.3 / F25）。本 store **不做**大小写
 *    预检——那是界面的校验，仓储撞上 UNIQUE 时抛的 `RepoError` 已经是
 *    「已存在同名记录」的中文，这里原样透传即可。
 * 2. **`deleteTag` 的 `force` 只绕过「系统标签不可删」这一条**（契约点名要求
 *    别想当然）：被任务引用时报的 `IN_USE` **无论 force 与否都会抛**。
 *    本 store 只是把 force 透传下去，全部判定在 `tagRepo.deleteTag` 里；
 *    抛出来的 `RepoError` 已经是中文，这里原样透传给界面。
 *    ⇒ 界面不能靠传 `force` 来跳过「这个标签还被 N 个任务用着」的提示。
 * 3. **`is_word` 是派生值**：它等于「是否勾选了名为『单词』的系统标签」，
 *    由 `taskStore` 在写入任务时结算，本 store 不碰。
 *
 * ⚠️ `tagsOfTask` 是**现查**不进缓存：任务→标签随时可能被别处改写
 * （`taskStore.editTask` / 回收站恢复后自动接回），缓存会给出陈旧结果。
 */

import { create } from 'zustand';
import * as tagRepo from '../repo/tagRepo';
import { fail, ok } from './ops';
import type { OpResult, TagStoreState } from './contracts';

export const useTagStore = create<TagStoreState>((set, get) => ({
  tags: [],

  /** 同步重读全部标签（`name ASC`）。 */
  refresh: () => {
    set({ tags: tagRepo.getAllTags() });
  },

  createTag: async (name: string, color: string): Promise<OpResult> => {
    try {
      // ⚠️ 返回 Promise<number>——`createTag` 是 async，必须 await。
      await tagRepo.createTag({ name, color });
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  renameTag: async (id: number, name: string, color: string): Promise<OpResult> => {
    try {
      // 编辑时的重名撞 UNIQUE 由仓储包成中文 `RepoError`（spec H8 的修复，
      // Flutter 版这里是直接崩溃）。本 store 不预先检查——照搬「编辑时不查重名」。
      await tagRepo.updateTag(id, { name, color });
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  /**
   * 删除标签（**连带清 `task_tags`**）。
   *
   * ⚠️ 外键 `ON DELETE CASCADE` 从未生效（没有 `PRAGMA foreign_keys=ON`），
   * 所以那次清理是必需的、由仓储负责，本 store 不自己写 SQL。
   *
   * @param force 越过系统标签保护（仓储语义）。
   */
  deleteTag: async (id: number, force = false): Promise<OpResult> => {
    try {
      await tagRepo.deleteTag(id, force);
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  /**
   * 一次性设置某个任务的标签集合（增删改都在一次调用里，全量覆盖）。
   *
   * ⚠️ 这是 `task_tags` 的**主要写入路径**，仓储内部已包事务
   * （Flutter 版不在事务里，DELETE 成功 + INSERT 失败会全丢——这里是修）。
   */
  setTagsForTask: async (
    taskId: number,
    tagIds: readonly number[],
  ): Promise<OpResult> => {
    try {
      await tagRepo.setTagsForTask(taskId, tagIds);
      return ok();
    } catch (e) {
      return fail(e);
    }
  },

  /** 某任务的标签，`name ASC`。同步现查，不缓存。 */
  tagsOfTask: (taskId: number) => tagRepo.getTagsForTask(taskId),
}));
