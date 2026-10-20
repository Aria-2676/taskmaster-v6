/**
 * 番茄钟时长与阶段流转（纯函数，无 DB / 无 UI）
 *
 * 对应 docs/migration/schema-v3.md §2.7（表结构）与 §3.4（mode 枚举）。
 * 与 points.ts / recurrence.ts 一样刻意不 import react-native：
 * 这几条规则写错会**静默产生脏数据**（记录里躺着 0 秒 / 负时长的番茄），
 * 必须能在没有手机的 Node 环境里直接回归。
 *
 * 两条最容易搞混的单位（§2.7 原文已注明，这里再钉一遍）：
 *  - `pomodoro_settings` 的 `*_duration` 单位是**分钟**；
 *  - `pomodoro_records` 的 `duration_seconds` / `actual_seconds` 单位是**秒**。
 * 换算只在本文件做一次，UI 层不要再乘 60。
 */

/** `pomodoro_records.mode` 的枚举值，与 §3.4 完全一致（小写字面量直存）。 */
export type PomodoroMode = 'work' | 'shortBreak' | 'longBreak';

/** `pomodoro_settings` 中与计时相关的四个字段，已换算成**分钟**的 camelCase 结构。 */
export type PomodoroSettings = {
  /** 专注时长（分钟） */
  workDuration: number;
  /** 短休息时长（分钟） */
  shortBreakDuration: number;
  /** 长休息时长（分钟） */
  longBreakDuration: number;
  /** 每完成 N 个专注后进一次长休息 */
  longBreakInterval: number;
};

/**
 * 默认设置，与 schema 里的列默认值一致（25 / 5 / 15 / 4）。
 *
 * 金样本里 `pomodoro_settings` 可能整行没种数据（它不在验收的 12 张表清单里），
 * 所以这一组值同时也是**读取失败时的兜底**，必须建库默认值对齐，否则两边会给出不同的时长。
 */
export const DEFAULT_POMODORO_SETTINGS: PomodoroSettings = {
  workDuration: 25,
  shortBreakDuration: 5,
  longBreakDuration: 15,
  longBreakInterval: 4,
};

/** 展示文案集中在这里，避免 UI 与通知各写一份导致措辞漂移。 */
export const POMODORO_MODE_LABEL: Record<PomodoroMode, string> = {
  work: '专注',
  shortBreak: '短休息',
  longBreak: '长休息',
};

/**
 * 分钟数兜底。
 *
 * 旧库里这些列虽然写了 `NOT NULL DEFAULT`，但迁移脚本可能留下 0 或负数；
 * Dart 侧读出来的也可能是 NaN。任何一种都不能让倒计时退化成负时长或 NaN 秒。
 */
function safeMinutes(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

/** 某个阶段的计划时长（秒）。settings 里的时长是分钟，这里统一 ×60。 */
export function durationSeconds(
  mode: PomodoroMode,
  settings: PomodoroSettings = DEFAULT_POMODORO_SETTINGS,
): number {
  switch (mode) {
    case 'shortBreak':
      return safeMinutes(settings.shortBreakDuration, DEFAULT_POMODORO_SETTINGS.shortBreakDuration) * 60;
    case 'longBreak':
      return safeMinutes(settings.longBreakDuration, DEFAULT_POMODORO_SETTINGS.longBreakDuration) * 60;
    case 'work':
    default:
      return safeMinutes(settings.workDuration, DEFAULT_POMODORO_SETTINGS.workDuration) * 60;
  }
}

/**
 * 完成一个**专注**之后该进入哪个休息阶段。
 *
 * 规则：累计完成数达到 `long_break_interval` 的整数倍 → longBreak，否则 shortBreak。
 * 边界：`completedWorkCount === 0` 时**不**进 longBreak（0 是任何数的整数倍，
 * 不特判的话「刚开始就被判该长休息」）。
 *
 * 注意这里**不是**通用的「下一个阶段」：休息结束回到 work 由调用方判断，
 * 因为那取决于刚结束的是什么阶段，而不是累计专注数。
 */
export function nextMode(
  completedWorkCount: number,
  settings: PomodoroSettings = DEFAULT_POMODORO_SETTINGS,
): PomodoroMode {
  const count = Number.isFinite(completedWorkCount) ? Math.max(0, Math.floor(completedWorkCount)) : 0;
  if (count === 0) return 'shortBreak';
  const interval = Math.floor(settings.longBreakInterval);
  if (!Number.isFinite(interval) || interval <= 0) return 'shortBreak';
  return count % interval === 0 ? 'longBreak' : 'shortBreak';
}

/**
 * 剩余秒数格式化成 `mm:ss`。
 *
 * - 负数 / NaN 按 0 处理（面板上不允许出现 `-1` 这种读数）；
 * - 分钟位**不进位到小时**，75 分钟就显示 `75:00`，方便用户一眼看出这是长时段；
 * - 小数向上取整：配合 `remainingSeconds` 的 ceil，起始瞬间显示的是满值（25:00）而不是 24:59。
 */
export function formatRemaining(seconds: number): string {
  const total = Math.max(0, Math.ceil(Number.isFinite(seconds) ? seconds : 0));
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`;
}

/**
 * 基于**墙钟**算剩余秒数。
 *
 * 刻意返回「剩余量」而不是让调用方每 tick 自减：自减会累积漂移，
 * 且后台被节流 / 掉帧后回来会直接算错。调用方只需记住 `endsAtMs`。
 */
export function remainingSeconds(endsAtMs: number, nowMs: number): number {
  if (!Number.isFinite(endsAtMs) || !Number.isFinite(nowMs)) return 0;
  return Math.max(0, Math.ceil((endsAtMs - nowMs) / 1000));
}
