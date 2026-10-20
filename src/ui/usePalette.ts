/**
 * 取当前调色板。界面组件一律用它拿颜色，不要自己判断亮暗、不要写死十六进制。
 */

import { useColorScheme } from 'react-native';
import { getPalette, type Palette } from './theme';
import { useThemeStore } from '../state/themeStore';

export function usePalette(): Palette {
  const mode = useThemeStore((s) => s.mode);
  const system = useColorScheme();
  // 'system' 时跟随系统；RN 的 useColorScheme 在极端情况下可能返回 null，兜底为浅色。
  const resolved = mode === 'system' ? (system === 'dark' ? 'dark' : 'light') : mode;
  return getPalette(resolved);
}

/** 给非组件代码（比如 StyleSheet.create 之外的地方）用的同步取色。 */
export function paletteFor(mode: 'light' | 'dark'): Palette {
  return getPalette(mode);
}
