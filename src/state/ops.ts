/**
 * 状态层共用的操作结果构造。
 *
 * 为什么单独一个文件：6 个 store 里「把异常翻成给用户看的中文」这件事要做
 * 十几次，各写一遍 catch 就会慢慢出现「有的地方塞了异常对象、有的地方塞了
 * 英文原文」。这里收口成两个函数，store 里只负责 try / catch 的边界。
 *
 * ⚠️ 凡是仓储抛出的 `RepoError`，`message` 已经是中文
 * （`repo/base.ts` 的 `toRepoError` 会做映射），可以直接展示、不要再包一层。
 * 未被映射的会带 SQLite 原文，那也比抛出栈信息强。
 */

import type { OpResult } from './contracts';

/** 成功。`message` 为 null 表示「不需要提示」（不是「没有提示文案」）。 */
export function ok(message: string | null = null): OpResult {
  return { ok: true, message };
}

/** 失败，把异常翻成可展示的中文。 */
export function fail(e: unknown): OpResult {
  return { ok: false, message: messageOf(e) };
}

/**
 * 异常 → 用户能看懂的中文。
 *
 * 绝不把异常对象本身塞进 `error` 字段——界面拿到 `[object Object]`
 * 或者 `UNIQUE constraint failed: tags.name` 都等于没弹。
 */
export function messageOf(e: unknown): string {
  if (e instanceof Error && e.message.length > 0) return e.message;
  return '操作失败，请重试';
}

/**
 * 表单里的描述文本 → 库里该存的值。
 *
 * spec §3.1 入口 1：`description = 输入框.trim()；空串 → null`。
 * 这一步不能省——仓储的重复检测走 `description IS NULL` 还是 `= ?` 两个分支
 * （`taskRepo.existsOnDateSql`），存 `''` 和存 `null` 会被判成两个不同任务。
 */
export function normalizeDescription(text: string | null | undefined): string | null {
  const trimmed = text?.trim();
  return trimmed !== undefined && trimmed.length > 0 ? trimmed : null;
}
