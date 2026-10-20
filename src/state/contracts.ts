/**
 * 状态层契约。
 *
 * 为什么先写契约：界面层要几个人分头写，如果各自去猜 store 长什么样，
 * 最后拼起来一定对不上。这份文件把 store 的**对外形状**钉死，
 * 实现方（src/state/*Store.ts）照它实现，界面方照它调用，两边可以并行。
 *
 * ⚠️ **异步性**——本项目最容易出隐蔽 bug 的地方：
 * `src/repo/` 下的函数**混着同步和异步**（底层 op-sqlite 的 `executeSync` 是同步、
 * `execute` 是异步）。更麻烦的是有 6 个函数**声明成 `export function` 却返回 Promise**：
 *
 *   pointsRepo: updateUserPoints, clearPointsRecords
 *   shopRepo:   deleteShopItem, deletePurchasedItem
 *   tagRepo:    assignTagToTask, removeTagFromTask
 *
 * 对这几个**漏掉 await 不会有任何编译错误**，只会静默产生竞态
 * （比如标签加上了但界面刷新在前，结果看起来"没生效"）。
 * 所以本文件里凡是返回 Promise 的方法，名字一律以 Async 无关的语义命名但**类型钉死为 Promise**，
 * 调用方必须 await。tsc 抓不到，只能靠 code review 与本文件这行提醒。
 *
 * 另：本文件**只有类型，没有实现**。实现放在同目录的 *Store.ts 里。
 */

import type {
  PointsRecordRow,
  Priority,
  PurchasedItemRow,
  Recurrence,
  RecycledTaskRow,
  ShopItemRow,
  TagRow,
  TaskRow,
} from '../repo/types';
import type { WarehouseGroup } from '../core/pointsRules';
import type { PurchaseResult } from '../repo/shopRepo';

/** 统一的操作结果。界面拿它决定弹什么提示，不用自己拼文案。 */
export interface OpResult {
  ok: boolean;
  /** 给用户看的中文提示。ok 时可为 null。 */
  message: string | null;
}

/* ── 任务 ──────────────────────────────────────────────────────────────── */

/** 新建任务的输入。字段与 `tasks` 表一一对应，不多不少。 */
export interface NewTaskInput {
  title: string;
  description?: string | null;
  /** 排期时间（cpl_time）。 */
  cplTime: Date;
  priority: Priority;
  rewardPoints: number;
  recurrence: Recurrence;
  /** 单词任务标记。 */
  isWord: boolean;
  tagIds?: readonly number[];
}

/** 编辑任务的输入。`updateAll=true` 时同步到该循环系列的后续实例。 */
export interface EditTaskInput extends NewTaskInput {
  id: number;
  updateAll?: boolean;
}

export interface TaskStoreState {
  /** 当前查看的日期。 */
  date: Date;
  /** 该日期的任务，已按仓储定义的顺序排好（五键排序 + id 兜底）。 */
  tasks: TaskRow[];
  loading: boolean;
  error: string | null;

  setDate: (d: Date) => void;
  /** 重新读库。同步查询，不需要 await。 */
  refresh: () => void;

  addTask: (input: NewTaskInput) => Promise<OpResult>;
  editTask: (input: EditTaskInput) => Promise<OpResult>;
  /**
   * 为一条循环任务模板补生成后续实例（调 `taskRepo.generateRecurringTasks`）。
   *
   * ⚠️ 该函数的窗口是「模板当天 00:00 → now+15 天」，**起点没有下界**：
   * 模板日期很旧时，会**从旧日期逐日回补**，凭空生成几十条历史实例（v5 已知缺陷）。
   * 所以：
   *   - **新建**循环任务后调用：安全，模板日期就是用户刚选的（今天或未来）。
   *   - **恢复**回收站里的循环任务后调用：**必须先把模板的 cpl_time 夹到今天**
   *     （只夹传给生成器的那一份副本，不改库里那行的原始日期），
   *     否则会把「三周前删除的每日任务」回补出几十条过期实例。
   */
  generateInstancesFor: (taskId: number) => Promise<void>;
  /** 完成 / 取消完成（积分联动在仓储内部完成，这里只负责刷新）。 */
  toggleComplete: (id: number) => Promise<OpResult>;
  /** 移入回收站（软删除）。 */
  removeTask: (id: number) => Promise<OpResult>;
  /** 连同循环系列的后续实例一起移入回收站。 */
  removeAllInstances: (id: number) => Promise<OpResult>;
  /** 启动时补扣逾期。返回补扣了几条。 */
  catchUpOverdue: () => Promise<number>;
}

/* ── 积分 ──────────────────────────────────────────────────────────────── */

export interface PointsStoreState {
  balance: number;
  /** 流水，最近的在前。 */
  records: PointsRecordRow[];
  /** 余额与流水净额是否一致。不一致说明有 bug，界面要能看出来。 */
  invariantOk: boolean;
  refresh: () => void;
}

/* ── 商城 ──────────────────────────────────────────────────────────────── */

export interface ShopStoreState {
  items: ShopItemRow[];
  purchased: PurchasedItemRow[];
  /** 仓库按商品名分组（同名多次购买归为一组，含 latest/oldest）。 */
  groups: WarehouseGroup<PurchasedItemRow>[];
  refresh: () => void;
  purchase: (shopItemId: number) => Promise<OpResult>;
  /** 用掉一件已购商品（删 oldest，不是 latest——v5 的语义，别搞反）。 */
  consume: (purchasedItemId: number) => Promise<OpResult>;
  /** 原始购买结果类型，供需要细分处理（余额不足等）的界面使用。 */
  lastPurchaseResult: PurchaseResult | null;
}

/* ── 标签 ──────────────────────────────────────────────────────────────── */

export interface TagStoreState {
  tags: TagRow[];
  refresh: () => void;
  createTag: (name: string, color: string) => Promise<OpResult>;
  renameTag: (id: number, name: string, color: string) => Promise<OpResult>;
  /**
   * ⚠️ `force` 的真实语义（照 `tagRepo.deleteTag` 的实现，别想当然）：
   * `force=true` **只**绕过「系统标签不可删除」这一条，
   * **不是**绕过「仍有任务在引用它」——被引用时无论 force 与否都会报 `IN_USE`。
   * 所以界面上「这个标签还被 N 个任务用着，删不掉」的提示，不能靠传 force 跳过。
   */
  deleteTag: (id: number, force?: boolean) => Promise<OpResult>;
  /** 一次性设置某个任务的标签集合（增删改都在一次调用里）。 */
  setTagsForTask: (taskId: number, tagIds: readonly number[]) => Promise<OpResult>;
  tagsOfTask: (taskId: number) => TagRow[];
}

/* ── 回收站 ────────────────────────────────────────────────────────────── */

export interface RecycleStoreState {
  items: RecycledTaskRow[];
  refresh: () => void;
  /** 恢复整条（循环任务会把系列一并恢复）。 */
  restore: (recycledTaskId: number) => Promise<OpResult>;
  /** 只恢复单个实例。 */
  restoreSingle: (recycledTaskId: number) => Promise<OpResult>;
  /** 永久删除。仓储内部已按 V6 三步规则清理 task_tags，界面不要自己碰 task_tags。 */
  permanentDelete: (recycledTaskId: number) => Promise<OpResult>;
  clearAll: () => Promise<OpResult>;
}

/* ── 设置 ──────────────────────────────────────────────────────────────── */

export interface SettingsStoreState {
  /** settings 表是 key-value。这里整表缓存，读用 get。 */
  values: Record<string, string>;
  refresh: () => void;
  get: (key: string, fallback: string) => string;
  getBool: (key: string, fallback: boolean) => boolean;
  getInt: (key: string, fallback: number) => number;
  set: (key: string, value: string) => Promise<OpResult>;
}
