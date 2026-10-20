/**
 * 路由契约。
 *
 * 为什么不用 React Navigation（V9 裁决，别再推翻重来）：
 * M1 只需要「底部三个 Tab + 若干压栈页面 + 弹窗」，自写栈导航约 150 行，
 * 比引入一个导航库（连带 gesture-handler / reanimated / screens 一串原生依赖）
 * 轻得多，也少一坨原生链接问题。
 *
 * 模型就两条：
 *   - **Tab 是一级容器**，切 Tab 会清空该 Tab 上的页面栈（回到该 Tab 的首页）。
 *   - **页面栈**在 Tab 之上压栈，返回键先弹栈，栈空了才退 App。
 */

/** 底部 Tab。三个，与 M1 范围一致。 */
export type TabName = 'Tasks' | 'Points' | 'Profile';

/** 可压栈的页面。与 Tab 同名的是各 Tab 的首页。 */
export type RouteName =
  | 'Tasks' // 任务列表（Tasks Tab 首页）
  | 'TaskDetail' // 任务详情
  | 'TaskEdit' // 新增/编辑任务（params.id 为空 = 新增）
  | 'Tags' // 标签管理
  | 'Recycle' // 回收站
  | 'Points' // 积分（Points Tab 首页）
  | 'Shop' // 商城
  | 'Warehouse' // 仓库（已兑换）
  | 'Profile' // 我的（Profile Tab 首页）
  | 'Settings' // 设置
  | 'Pomodoro' // 番茄钟
  | 'DevPanel'; // 开发者面板（Spike 验收台，藏在设置里）

/** 压栈时带的参数。各页面自己按需取，用 `as` 收紧类型。 */
export type RouteParams = Record<string, unknown>;

export interface Route {
  name: RouteName;
  params?: RouteParams;
}

/** 每个页面落在哪个 Tab 上——决定了「跨 Tab 压栈」时底部该高亮谁。 */
export const ROUTE_TAB: Record<RouteName, TabName> = {
  Tasks: 'Tasks',
  TaskDetail: 'Tasks',
  TaskEdit: 'Tasks',
  Tags: 'Tasks',
  Recycle: 'Tasks',
  Points: 'Points',
  Shop: 'Points',
  Warehouse: 'Points',
  Profile: 'Profile',
  Settings: 'Profile',
  Pomodoro: 'Profile',
  DevPanel: 'Profile',
};

/** 每个 Tab 的首页路由名。切回该 Tab 时用它重置页面栈。 */
export const TAB_ROOT: Record<TabName, RouteName> = {
  Tasks: 'Tasks',
  Points: 'Points',
  Profile: 'Profile',
};

/**
 * 需要以「弹窗」形态呈现的页面（从底部升起、带遮罩），
 * 剩下的都是整页压栈。渲染层据此决定转场。
 */
export const MODAL_ROUTES: ReadonlySet<RouteName> = new Set<RouteName>(['TaskEdit']);
