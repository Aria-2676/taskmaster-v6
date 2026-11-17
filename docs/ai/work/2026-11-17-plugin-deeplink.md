# 任务 · 插件实例化参数（带参数打开，deeplink 前置）

> 日期：2026-11-17 ｜ 状态：review
> 协调者：用户 ｜ 实现者：小鱼 ｜ 核查者：用户

## 范围

- 要做：
  1. 打开插件时可以带一份初始参数（`Map<String, Object?>`），主包在页面加载完成后
     注入到 `window.__hostOpen` 并派发 `host-open` 事件。
  2. 计划插件消费这个参数：带 `planId` 时直接进那条计划的详情，不带时行为不变。
  3. 今日页计划块把 `planId` 传下去 —— 点「Reading 33%」进的就是 Reading，
     而不是"先进列表，再自己找一遍"。
- 明确不做：
  - 全局搜索本体（6.8）。这个任务只把"能带参数打开"这条能力打通，
    搜索是它的第一个批量使用者，下一轮做。
  - 不做参数校验/白名单：参数是自己主包传的，不来自外部输入。

## 涉及文件/目录

- `lib/app/pages/plugin_page.dart`（加载后注入参数）
- `lib/app/data/plugin_bridge.dart` 或 LaunchSpec（携带参数）
- `plugins/src/plan_mode/index.html`、`query.html`（返回 id、消费 planId）
- `lib/app/pages/today_page.dart`（计划块带 id 打开）
- `docs/plugin-contract.md`（新增 `host-open` 说明）

## 依赖

- 前置任务：无
- 需要裁决：**技术选型已定**（见下），不需要用户裁决

### 选型：为什么是"注入 + 事件"而不是 URL 参数

`PluginPage` 用 `WebViewController.loadFile(path)` 加载。三种让插件拿到参数的办法：

| 方案 | 问题 |
|---|---|
| `loadRequest(Uri.file(path).replace(queryParameters: …))` | `file://` 带 query 时 WebView 可能把 `?x=1` 当成文件名的一部分，直接白屏。**改加载路径的风险太大**——2026-11-16 已经在加载链上踩过坑 |
| URL fragment | 同上，`loadFile` 不保证保留 |
| **加载完成后 `runJavaScript` 注入 + 派发事件** | 改动只在页面加载之后，不碰加载方式；插件侧加 5 行监听 |

选第三种，并且**双保险**：
- `window.__hostOpen = params`（已经在跑的页面，插件随时可以读）
- `window.dispatchEvent(new CustomEvent('host-open', { detail: params }))`（刚打开、插件已注册监听）
插件侧：先注册监听，再检查 `__hostOpen` 是否已有值 —— 两个时机都覆盖到。

## 验收

- 机器判定：无单测可测（WebView 注入依赖真机/模拟器），靠下面的人工项
- 人判定：
  1. 今日页点「计划」块里的某条 → 插件直接打开**那条计划**的详情
  2. 从侧边栏进计划插件 → 还是列表页（没带参数，行为不变）
  3. 带参数打开后点返回 → 回到**列表**，不是直接退出插件
- 验收清单：`docs/acceptance/2026-11-17-plugin-deeplink.md`

## 风险

- 契约：新增 `host-open` 事件，写进 `docs/plugin-contract.md`；老插件不监听不受影响
- 数据：无
- 真机：注入时机依赖 `onPageFinished`，插件如果在 DOMContentLoaded 之前就读参数会读不到 ——
  所以要求插件侧同时检查 `__hostOpen`
- 发布：主包和计划插件都要发版才生效

## 交接区

### 已完成

- `PluginLaunchSpec.openWith` / `PluginPage.openWith` / `PluginView.openWith`
- `_injectOpenWith`：加载完成后写 `window.__hostOpen` + 派发 `host-open`，
  并留一条 `[plugin] 注入 openWith …` 日志（不然"没落到详情"根本分不清是谁的问题）
- 计划插件 2.0.7：`query.html` 返回 `id`；`index.html` 在 `loadPlans` 之后消费参数，
  计划已删时 toast
- 今日页计划行各自可点，带自己的 id
- `docs/plugin-contract.md` §5.1

### 下一步

6.8 全局搜索可以直接用这套：搜索结果带 `{kind:'plan'|'memo'|'list', id}` 打开。
备忘和清单要各自加"按 id 定位"的消费逻辑（备忘没有详情页，可能只需要滚动到那条）。

### 已知坑

- **改 `PluginPage` 构造时漏了 `this.openWith,`**，analyze 却"通过"了 ——
  因为我用 `grep -E "^(error|warning)"` 过滤，而 flutter analyze 的输出行首有空格。
  `^error` 匹配不到任何错误，于是全量测试才炸出编译错误。
  **教训：过滤 analyze 输出别用 `^`。**
- 市场里点"升级"按钮在这个模拟器上极难命中（坐标比例各页面不一致），
  最后是误判为"没升"而实际升了 —— 用插件诊断页看版本号才确认。

### 未验证

- `host-open` 事件单独生效（实测无法区分是哪条路径先到）
- 计划已删时的 toast
