/**
 * 设计令牌：颜色 / 间距 / 圆角 / 字号。
 *
 * 为什么先定这个：界面层会由多个人分头写几个界面。
 * 没有统一令牌的话，颜色会各写各的十六进制，最后拼起来不是一个 App，
 * 而且改主题时要改几十处。所以**任何界面都不许自己写死颜色**，一律从这里取。
 *
 * 取值来源：`src/repo/types.ts` 里已经定死的枚举，不是我编的——
 *   Priority = 'red' | 'orange' | 'yellow' | 'blue' | 'white'（**没有黑色**，white 是最低档）
 *   Recurrence = 'none' | 'daily' | 'weekly' | 'monthly'（**没有 yearly**）
 */

import type { Priority } from '../repo/types';

/** 主题模式。'system' 跟随系统，由设置项提供。 */
export type ThemeMode = 'system' | 'light' | 'dark';

export interface Palette {
  /** 页面底色 */
  bg: string;
  /** 卡片/列表项表面色 */
  surface: string;
  /** 次级表面（输入框、分组头、Tab 栏） */
  surfaceAlt: string;
  /** 主文本 */
  text: string;
  /** 次级文本（说明、时间戳） */
  textDim: string;
  /** 分隔线与描边 */
  border: string;
  /** 主色（按钮、选中态） */
  primary: string;
  /** 主色上的文字（按钮字） */
  onPrimary: string;
  /** 危险操作（删除、扣分） */
  danger: string;
  /** 正向（完成、加分） */
  success: string;
  /** 底部 Tab 栏背景 */
  tabBg: string;
  /** 未选中的 Tab */
  tabInactive: string;
  /** 遮罩层 */
  overlay: string;
}

const light: Palette = {
  bg: '#F5F5F5',
  surface: '#FFFFFF',
  surfaceAlt: '#EFEFEF',
  text: '#1F1F1F',
  textDim: '#757575',
  border: '#E0E0E0',
  primary: '#2196F3',
  onPrimary: '#FFFFFF',
  danger: '#E53935',
  success: '#43A047',
  tabBg: '#FFFFFF',
  tabInactive: '#9E9E9E',
  overlay: 'rgba(0,0,0,0.45)',
};

const dark: Palette = {
  bg: '#121212',
  surface: '#1E1E1E',
  surfaceAlt: '#2A2A2A',
  text: '#EDEDED',
  textDim: '#9E9E9E',
  border: '#333333',
  primary: '#64B5F6',
  onPrimary: '#102027',
  danger: '#EF5350',
  success: '#66BB6A',
  tabBg: '#1A1A1A',
  tabInactive: '#757575',
  overlay: 'rgba(0,0,0,0.6)',
};

export const palettes: Record<'light' | 'dark', Palette> = { light, dark };

export function getPalette(mode: Exclude<ThemeMode, 'system'>): Palette {
  return palettes[mode];
}

/**
 * 优先级指示色。
 *
 * ⚠️ 两个反直觉的点，改之前先想清楚：
 * 1. **没有黑色档**——white 就是最低优先级，不是"未设置"。
 * 2. 纯黄 `#FFEB3B` 在浅底上几乎看不见，所以黄用的是加深的琥珀色；
 *    white 在浅底上和白卡片融为一体，必须**配一条描边**才看得见。
 *    所以这里返回的是 `{color, border}`，不是单个颜色。
 */
export function priorityIndicator(p: Priority): { color: string; border: string } {
  switch (p) {
    case 'red':
      return { color: '#E53935', border: '#E53935' };
    case 'orange':
      return { color: '#FB8C00', border: '#FB8C00' };
    case 'yellow':
      return { color: '#FBC02D', border: '#FBC02D' };
    case 'blue':
      return { color: '#1E88E5', border: '#1E88E5' };
    case 'white':
      return { color: '#FAFAFA', border: '#BDBDBD' };
    default: {
      // 穷尽性兜底：将来若新增优先级，这里会在编译期报错提醒补色，
      // 而不是静默渲染成透明。
      const _never: never = p;
      return { color: _never, border: _never };
    }
  }
}

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const radius = {
  sm: 6,
  md: 10,
  lg: 16,
  pill: 999,
} as const;

export const fontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 21,
  xxl: 27,
} as const;
