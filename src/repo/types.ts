/**
 * 数据契约的类型定义（14 张表的行类型）。
 *
 * ## 唯一权威来源
 *
 * 列名**一律以 `lib/core/services/database/database_schema_mixin.dart` 的 DDL 为准**，
 * 其次是 `rn/src/db/schema.ts`（已逐列核对一致），最后才是 `docs/migration/schema-v3.md`——
 * **那份文档的 §2.5 / §3.3 有错**（见下），不要拿它当契约。
 *
 * 这些类型是**数据库行的形状**，不是 UI 模型。字段名严格用真实列名，
 * 这样任何人都能拿一个对象去和 `SELECT` 结果对照。
 * UI 层要用的视图模型请在各自模块里定义，不要往这里加只在界面存在的字段。
 *
 * ## 曾经踩过的坑（别再犯）
 *
 * 本文件早先有一版类型，是照 `schema-v3.md` 写的，而那份文档这几节本身是错的，
 * 导致 `shop_items.cost_points`、`purchased_items.item_name` 等一批**不存在的列**
 * 被写进了类型。照那些类型写出来的 SQL 会在运行时才炸。
 * → **写任何涉及列名的代码前，先回 DDL 原文核对。**
 */

import type { PointsRecordType } from '../core/pointsRules';

/** `tasks.priority` 取值。注意没有黑色，白色是最低档。 */
export type Priority = 'red' | 'orange' | 'yellow' | 'blue' | 'white';

/** `tasks.recurrence` 取值——**没有 yearly**，别自造。 */
export type Recurrence = 'none' | 'daily' | 'weekly' | 'monthly';

/** `pomodoro_records.mode` 取值。 */
export type PomodoroMode = 'work' | 'shortBreak' | 'longBreak';

// ── 任务 ────────────────────────────────────────────────────────────────

/** `tasks` 表行。 */
export interface TaskRow {
  id: number;
  loop_id: string | null;
  title: string;
  description: string | null;
  /** 是否背单词类任务（`is_word`）。⚠️ 它由「单词」**系统标签**的勾选状态派生，
   *  不是独立字段——所以 SEED_SQL 必须插入 4 个默认标签，否则该联动失效。 */
  is_word: number;
  /** 0=未完成 1=已完成。 */
  is_ok: number;
  /** 排期时间（ISO8601 本地字符串）。**NOT NULL**，没有「无期限」这种取值。 */
  cpl_time: string;
  recurrence: Recurrence;
  completed_at: string | null;
  reward_points: number;
  /** 逾期扣分是否已执行过（0/1）。**先扣分成功后才置 1**，顺序反了会重复扣。 */
  is_deducted: number;
  created_at: string;
  priority: Priority;
}

/** `recycled_tasks` 表行。与 `tasks` 同结构，额外两列。 */
export interface RecycledTaskRow {
  /** ⚠️ **这是回收站自己的自增主键，与原任务无关。**别拿它当原任务 id。 */
  id: number;
  /**
   * **原任务 id**。H1 修复（防止删除→恢复→重复刷分）完全依赖这一列：
   * 恢复时必须按它写回原 id，否则 `points_records.related_id` 与 `task_tags.task_id` 全部悬空。
   * 建表时该列可空，**但 RN 侧写入时必须填**。
   */
  task_id: number | null;
  /** 循环任务系列 id，必须保留——否则恢复后不再生成后续实例。 */
  loop_id: string | null;
  title: string;
  description: string | null;
  is_word: number;
  is_ok: number;
  cpl_time: string;
  recurrence: Recurrence;
  completed_at: string | null;
  reward_points: number;
  is_deducted: number;
  created_at: string;
  priority: Priority;
  /** 进回收站的时间，**NOT NULL**；裁剪到 10 条时按它倒序。 */
  deleted_at: string;
}

// ── 标签 ────────────────────────────────────────────────────────────────

/** `tags` 表行。`color` 是**字符串**形如 `'#2196F3'`，**不是** ARGB 整数。 */
export interface TagRow {
  id: number;
  /** `NOT NULL UNIQUE`。SQLite 默认 BINARY 排序 → **DB 层大小写敏感**，
   *  而 UI 层做重名校验时通常忽略大小写——两者不一致是既有行为，照搬。 */
  name: string;
  /** `NOT NULL DEFAULT '#2196F3'`。 */
  color: string;
  /**
   * Material 图标名（`translate` / `work` / `school` / `home`）。
   * ⚠️ **纯死数据**：Flutter 侧从未读取该列渲染，UI 一律用同一个图标。照存不渲染即可。
   */
  icon: string | null;
  /** 系统标签不可删。「单词」是 `is_system = 1`，`is_word` 联动靠它。 */
  is_system: number;
  created_at: string;
}

/** `task_tags` 表行（复合主键天然去重；可能含孤儿行，外键从未开启）。 */
export interface TaskTagRow {
  task_id: number;
  tag_id: number;
}

// ── 积分 ────────────────────────────────────────────────────────────────

/** `user_points` 表行。`id` 恒为 1，但**无 CHECK 约束**，单行性靠代码约定。 */
export interface UserPointsRow {
  id: number;
  points: number;
  updated_at: string;
}

/**
 * `points_records` 表行。
 *
 * ⚠️ `description` 是 **NOT NULL 的文案快照**，不是可空字段。
 * 缺失它会让明细页没有任何文案可显示。
 */
export interface PointsRecordRow {
  id: number;
  /** **永远带符号**（扣分为负）。明细页靠它判断收支，不做绝对值处理。 */
  points: number;
  /** 7 种之一（见 `core/pointsRules.ts` 的 `PointsRecordType`）。 */
  type: PointsRecordType;
  /** 展示文案，NOT NULL。 */
  description: string;
  /**
   * 关联对象 id，**按 `type` 解释**：
   * - `task_complete` / `task_uncomplete` / `overdue_deduct` → `tasks.id`
   * - `shop_purchase` → **`shop_items.id`**（**不是** `purchased_items.id`）
   * - `scratch_win` / `scratch_refund` → **NULL**（Flutter 侧根本没传 relatedId）
   * - `scratch_cost` → `scratch_tickets.id`
   */
  related_id: number | null;
  created_at: string;
}

// ── 商城 ────────────────────────────────────────────────────────────────

/** `shop_items` 表行——商品定义。**没有库存字段，也没有 `is_active`**。 */
export interface ShopItemRow {
  id: number;
  name: string;
  /** `NOT NULL`。 */
  description: string;
  /** 积分数，无小数。 */
  price: number;
  created_at: string;
  /** Material 图标名，未命中映射表时静默降级为 `shopping_bag`。 */
  icon_name: string;
  /** ARGB **整数**——与 `tags.color`（字符串）是两种类型，**不可混用解析函数**。 */
  color_value: number;
}

/**
 * `purchased_items` 表行——**快照**，存的是兑换当时的展示字段。
 * 商品后来改名或改价，历史记录不受影响。
 * ⚠️ 仓库页按**快照 `name` 字符串**分组（不是 `shop_item_id`）：改名会分裂成两组，
 * 重名会合并成一组。这是既有行为，M1 照搬。
 */
export interface PurchasedItemRow {
  id: number;
  /** 指向 `shop_items.id`；商品被物理删除后变成悬空引用，**无外键约束**。 */
  shop_item_id: number | null;
  name: string;
  description: string;
  price: number;
  purchased_at: string;
  icon_name: string;
  color_value: number;
}

// ── 番茄钟 ──────────────────────────────────────────────────────────────

/** `pomodoro_settings` 表行，`id` 恒为 1。**时长单位是分钟**（记录表是秒，别搞混）。 */
export interface PomodoroSettingsRow {
  id: number;
  work_duration: number;
  short_break_duration: number;
  long_break_duration: number;
  long_break_interval: number;
  sound_enabled: number;
  vibration_enabled: number;
  notification_enabled: number;
  auto_start_break: number;
  auto_start_work: number;
}

/** `pomodoro_records` 表行。时长单位是**秒**。 */
export interface PomodoroRecordRow {
  id: number;
  mode: PomodoroMode;
  duration_seconds: number;
  /** 真实经历秒数，**暂停时长不计入**。 */
  actual_seconds: number;
  start_time: string;
  end_time: string | null;
  /** 关联任务 id；H1 修复需要一并处理这一列（改 id 时同步）。 */
  related_task_id: number | null;
  related_task_title: string | null;
  is_completed: number;
  created_at: string;
}

// ── 展示辅助 ────────────────────────────────────────────────────────────

/** 优先级从高到低的展示顺序。 */
export const PRIORITY_ORDER: Priority[] = ['red', 'orange', 'yellow', 'blue', 'white'];

/** 优先级中文名。 */
export const PRIORITY_LABEL: Record<Priority, string> = {
  red: '高',
  orange: '较高',
  yellow: '中',
  blue: '较低',
  white: '低',
};