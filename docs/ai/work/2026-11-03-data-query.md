# 任务 · 6.2.1 数据交互层最小版（契约 provides + 计划模式响应 plan.list）

> 日期：2026-11-03 ｜ 状态：in_progress
> 协调者：用户 ｜ 实现者：WorkBuddy ｜ 核查者：用户

## 范围

- 要做：
  1. bootstrap 注入 `window.host.onQuery(method, handler)` —— 插件注册"我能答什么"
  2. 主包反向 RPC：`runJavaScript('window.__hostQuery(callId, method, params)')`，
     插件通过 `HostBridge` 回 `{queryReply, callId, ok, result}`，主包按 id 匹配 + 超时
  3. 计划模式注册 `plan.list`，返回它自己的计划（本版先返回固定结构，验证通道）
  4. `plugin.json` 加 `provides` 字段（声明可被查询的实体），索引同步
- 明确不做：
  - 通用查询协议（只跑通一条 `plan.list`）
  - 今日页（6.3）
  - **无页面查询**（见下方"已知坑"，这是阻塞今日页的关键问题）

## 涉及文件/目录

- `lib/app/pages/plugin_page.dart`（bootstrap + 反向 RPC + 超时）
- `lib/core/plugin/plugin_manifest.dart`（`provides` 字段）
- `lib/core/plugin/plugin_index.dart`（索引同步）
- `plugins/src/plan_mode/index.html` + `plugin.json`
- `docs/plugin-contract.md`（契约补充）
- `docs/decisions.md`（已写：请求式查询）

## 依赖

- 前置任务：无（`docs/decisions.md` 2026-11-03 两条决策已定）
- 需要裁决：**无页面时怎么查**（见下）

## 验收

- 机器判定：
  - 通道测试：假插件 handler 返回值能被主包拿到
  - 超时测试：handler 不返回时，主包 2 秒后拿到"超时"而不是卡死
  - 未注册的方法返回"不支持"，不是异常
- 人判定：打开计划模式页面，主包调试入口能查到 `plan.list` 的结果
- 验收清单：`docs/acceptance/2026-11-03-data-query.md`（完成后补）

## 风险

- 契约：新增 `provides` 是**新增字段**，`contract` 不 +1（按 capabilities.md:24 的判据）
- 真机：WebView 反调 `runJavaScript` 的时序没验证过（页面 ready 之前调用会丢）

## 交接区

### 已完成

- 读 `plugin_page.dart`：现有 bridge 是**单向**（插件 → 主包 `host.call`；
  主包 → 插件只有 `__hostEvent` 广播，无返回值）。反向 RPC 需要新增。

### 下一步

- 实现 bootstrap 的 `onQuery` + `__hostQuery`
- 主包侧 `PluginQueryChannel`（callId → Completer、超时、页面切换时 reject 全部）

### 已知坑/失败尝试

- **插件页面没打开时，WebView 不存在，主包查不到任何数据。**
  这意味着今日页（6.3）如果要显示"今日计划"，光有查询协议不够。

### 已验证（2026-11-03 20:29，模拟器 Android 17 / SDK 37）

**离屏 WebView 可行**，探针结果（main.dart 临时注入，验证后已删）：

```
[PROBE] channel: page-alive              ← HTML 里的 JS 执行了
[PROBE] runJavaScriptReturningResult => 2 ← 能同步取返回值
[PROBE] channel: alive-after-3s          ← 3 秒后仍存活
```

结论：`webview_flutter` 的 `WebViewController()` **不挂 `WebViewWidget`** 也能
`loadHtmlString` / `runJavaScript` / 通过 `JavaScriptChannel` 回传。
→ 用户选的**方案 D（双入口 + 离屏）可行**，插件加一个 `queryEntry` 极简页即可。

### 下一步

按 D 补：`plugin.json` 的 `queryEntry` 字段 + 主包侧离屏管理器
（按需创建 / 加载 queryEntry / 空闲销毁）。
