/**
 * 导航状态（Zustand）。
 *
 * 两个约定，改动前先读：
 * 1. `stack[0]` **永远是该 Tab 的首页**，所以栈长度至少为 1。
 *    「栈空」不存在，「回到首页」= 栈裁到只剩 1 个。
 * 2. 跨 Tab 压栈（比如在任务页压出商城页）会**切换 Tab 并重置那个 Tab 的栈**，
 *    而不是把别的 Tab 的页面压到当前 Tab 上——否则底部高亮和返回行为会自相矛盾。
 */

import { create } from 'zustand';
import { ROUTE_TAB, TAB_ROOT, type Route, type RouteName, type RouteParams, type TabName } from './routes';

export interface NavState {
  tab: TabName;
  /** 当前 Tab 上的页面栈。stack[0] 是首页，栈顶是当前可见页。 */
  stack: Route[];
  push: (name: RouteName, params?: RouteParams) => void;
  /** 弹栈。栈已在首页时返回 false（调用方据此决定要不要退 App）。 */
  pop: () => boolean;
  replace: (name: RouteName, params?: RouteParams) => void;
  switchTab: (tab: TabName) => void;
  /** 回到当前 Tab 的首页（清掉栈上所有页面）。 */
  popToRoot: () => void;
}

export const useNavStore = create<NavState>((set, get) => ({
  tab: 'Tasks',
  stack: [{ name: TAB_ROOT.Tasks }],

  push: (name, params) => {
    const target = ROUTE_TAB[name];
    const { tab, stack } = get();
    if (target !== tab) {
      // 跨 Tab：切过去，并把那个 Tab 的栈重置为「首页 + 目标页」
      set({ tab: target, stack: [{ name: TAB_ROOT[target] }, { name, params }] });
      return;
    }
    set({ stack: [...stack, { name, params }] });
  },

  pop: () => {
    const { stack } = get();
    if (stack.length <= 1) return false;
    set({ stack: stack.slice(0, -1) });
    return true;
  },

  replace: (name, params) => {
    const { stack } = get();
    set({ stack: [...stack.slice(0, -1), { name, params }] });
  },

  switchTab: (tab) => {
    const { tab: current, stack } = get();
    if (tab === current) {
      // 再点当前 Tab = 回到该 Tab 首页（常见的 UX 约定）
      if (stack.length > 1) set({ stack: stack.slice(0, 1) });
      return;
    }
    set({ tab, stack: [{ name: TAB_ROOT[tab] }] });
  },

  popToRoot: () => {
    const { stack } = get();
    if (stack.length > 1) set({ stack: stack.slice(0, 1) });
  },
}));
