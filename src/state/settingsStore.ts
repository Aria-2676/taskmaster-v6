/**
 * 设置状态：`settings` 表（key-value）的整表缓存 + 类型化读取。
 *
 * ⚠️ **本 store 不碰 SQL**，读写全部走 `src/repo/settingsRepo.ts`
 * （与其余 5 个 store 同一条纪律：数据访问只在 `src/repo/`）。
 *
 * ── 用法约定 ──────────────────────────────────────────────────────────
 * - 数据库打开后（App 外壳负责 `openDatabase`），**必须先 `refresh()` 一次**
 *   再读，否则 `values` 是空的、所有 `get*` 都返回 fallback。
 * - 首次启动 `SEED_SQL` 已播种 16 个键，所以正常路径下 fallback 用不到；
 *   拿到 fallback 通常意味着键名拼错了。
 *
 * ── 值一律是 TEXT，转换规则收在本文件 ─────────────────────────────────
 * `settingsRepo` 刻意不做隐式转换（那正是 v5 里「`'false'` 被当成真」的由来），
 * 所以 `getBool` / `getInt` 放在这里——它们是**展示口径**，不是数据访问。
 */

import { create } from 'zustand';
import * as settingsRepo from '../repo/settingsRepo';
import { fail, ok } from './ops';
import type { OpResult, SettingsStoreState } from './contracts';

export const useSettingsStore = create<SettingsStoreState>((set, get) => ({
  values: {},

  /** 同步整表重读（16 行，一次性读完）。 */
  refresh: () => {
    set({ values: settingsRepo.getAllSettings() });
  },

  /**
   * 取字符串值。
   *
   * ⚠️ 缓存里没有这个键时返回 `fallback`——**不回库再查一次**：
   * 回库会让「键名拼错」和「真的没这个键」在开发期看起来一模一样，
   * 而整表缓存本来就该在 refresh 时一次拿全。
   */
  get: (key: string, fallback: string) => {
    const v = get().values[key];
    return v === undefined ? fallback : v;
  },

  /**
   * 取布尔值。**只有字符串 `'true'` 才是真**，其余（包括 `'false'`）一律假。
   *
   * ⚠️ 绝不写成 `Boolean(v)` 或 `!!v`——非空字符串 `'false'` 会被判成 true，
   * 那是 v5 真实踩过的坑（settingsRepo 顶部注释里有记）。
   */
  getBool: (key: string, fallback: boolean) => {
    const v = get().values[key];
    return v === undefined ? fallback : v === 'true';
  },

  /** 取整数。解析不出合法数字时返回 fallback（不返回 0——0 本身也是个值）。 */
  getInt: (key: string, fallback: number) => {
    const v = get().values[key];
    if (v === undefined) return fallback;
    const n = Number.parseInt(v, 10);
    return Number.isNaN(n) ? fallback : n;
  },

  /**
   * 写入一个键（`INSERT OR REPLACE`）。
   *
   * ⚠️ 是**异步**的（仓储走 `writeBatch` → `executeBatch`），必须 await。
   * 写成功后直接更新缓存里的那一项，不整表重读。
   */
  set: async (key: string, value: string): Promise<OpResult> => {
    try {
      await settingsRepo.setSetting(key, value);
      set({ values: { ...get().values, [key]: value } });
      return ok();
    } catch (e) {
      return fail(e);
    }
  },
}));
