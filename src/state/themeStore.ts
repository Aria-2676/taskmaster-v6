/**
 * 主题模式。
 *
 * ⚠️ 当前 `mode` 只存在内存里，**还没接 settings 表**（等设置仓储的 API 面确认后再接，
 * 不要在这里伪造一个读库调用假装接好了）。所以现在重启 App 会回到 'system'。
 * 接线时改 `hydrate()` 这一处即可，界面层不用动。
 */

import { create } from 'zustand';
import type { ThemeMode } from '../ui/theme';

export interface ThemeState {
  /** 'system' 跟随系统；另两个是强制。 */
  mode: ThemeMode;
  setMode: (mode: ThemeMode) => void;
  /** 从设置表读回用户的主题偏好。目前未接线。 */
  hydrate: () => Promise<void>;
}

export const useThemeStore = create<ThemeState>((set) => ({
  mode: 'system',
  setMode: (mode) => set({ mode }),
  hydrate: async () => {
    // TODO(设置层接线后补)：读取 settings 表的 themeMode 键并 setMode。
    // 现在保持 'system'。
  },
}));
