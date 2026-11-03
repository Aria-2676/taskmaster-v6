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


---

## 2026-11-03 21:40 已解决：今日页计划块

定位过程（按日志逐段切分，两个真因）：

1. **`installDir` 是相对路径**（`plan_mode/1.3.0`），拿去 `File()` 找不到清单。
   改用 `PluginInstaller.directoryOf(plugin)` 取绝对路径。
2. **清单文件名是 `plugin.json`，不是 `manifest.json`** —— 我按后者写的，
   文件不存在 → 解析返回 null → `queryEntry` 永远读到 null。
3. 顺带修：**就绪判定不能靠"onPageFinished 到了"**。bootstrap 注入是异步的，
   注入完插件还要自己把 handler 挂上。改成主包轮询 `typeof window.host`
   确认注入成功，再多等一拍；插件侧也主动上报 `{queryReady:true}` 作为双保险。

**结果**：模拟器上全链路通

```
清单=plan_mode queryEntry=query.html
loadFile 返回 → bootstrap 注入成功 → 已就绪
acquire 返回 true → 开始查询 plan.list
```

今日页出现「未来七天」块，空数据显示「这周还没有安排」（正确）。

**未验证**：有任务时的日期芯片渲染（清过数据，没有任务可测）。

## 2026-11-03 21:20 记录（已解决，保留过程）

**现象**：进今日页，日志只有两行

```
[today] 加载计划块：plan_mode v1.3.0
[today] 加载计划块：plan_mode v1.3.0
```

之后**没有任何输出**（无异常、无超时、无 `[query-host]`）。界面上"未来七天"块不出现
（连"读取中…"也没有）。

**已排除**：
- 不是 ready 超时 —— 超时会打 `[query-host] ... 没在 6s 内就绪`，没有。
- 不是查询超时 —— 查询超时会打 `[query-host] ... 查询超时`，没有。
- 插件确实装了（市场显示 plan_mode v1.3.0），`query.html` 在包里。

**怀疑卡在**：
1. `widget.pluginLauncher(plugin)` —— 构造 `PluginBridge` 时可能有异步步骤没回来；
2. `WebViewController.loadFile()` —— 离屏实例首次 loadFile 挂起（探针用的是
   `loadHtmlString`，不是 `loadFile`，两者的路径不同）。

**下一步**：在这两处各加一条 `debugPrint` + `try/catch` 包裹，先定位卡点；
`loadFile` 若真挂起，改用 `loadHtmlString` + 手动读文件内容（探针验证过这条路可行）。

**影响**：块不显示时今日页本身正常（主包部分照常渲染），所以**不影响已发的 6.1.4**。

---

## 2026-11-03 22:18 6.4.0 验证通过（备忘插件 + 今日页置顶块）

模拟器全链路：

```
plan_mode loadFile → memo loadFile → 两个都 bootstrap 注入成功 → 都就绪
今日页：置顶备忘 📌 PinnedMemoCheck / 未来七天 这周还没有安排
```

备忘插件自身：记录（PinnedMemoCheck）→ 置顶（出现「置顶」分区、边框高亮、
按钮变「取消置顶」）→ 今日页读到。

**踩到一个环境坑**：新插件推上去后，市场仍显示旧列表（周计划还是 1.2.3、没有备忘）。
原因是索引首源 `gcore.jsdelivr.net` 对分支引用有约 12 小时缓存，而回退链只在
**首源失败**时才往下走，不会"取最新"。验证时用
`--dart-define=GAME_CDN_BASE=https://raw.githubusercontent.com/...` 绕过。

**这条要不要改**：每次上/改插件都会遇到同样问题（发布脚本 purge 了清单，但这个
构建是本地测试没走发布）。候选方案：索引也做多源并发取最新；或本地验证统一用上面
的 dart-define。暂不阻塞 6.4。
