# 任务 · 诊断能力：插件页信息面板 + 本地日志

> 日期：2026-11-17 ｜ 状态：review
> 协调者：用户 ｜ 实现者：小鱼 ｜ 核查者：用户

## 范围

- 要做：
  1. **运行日志环形缓冲**：把 `debugPrint` 的输出收进内存（时间戳 + tag + 内容），
     上限条数固定，超出丢最旧。不落盘、不上报。
  2. **插件页诊断面板**：插件页 AppBar 加入口，显示插件 id / 版本 / 契约 / 权限 /
     查询入口 / 是否离屏可用，外加该插件最近 N 条错误（按 tag 过滤）。
     「复制」一键把整段信息放进剪贴板。
  3. **设置页「诊断与日志」**：整份日志预览 + 复制 + 清空。
- 明确不做：
  - 不做远端上报 / 崩溃收集（隐私，且用户没要）
  - 不做日志文件持久化轮转（这一轮先解决"看得见"，落盘等有需求再说）
  - 不改插件契约（诊断是主包能力，插件不需要配合）

## 涉及文件/目录

- `lib/core/diagnostics/app_log.dart`（新）
- `lib/main.dart` 或 `lib/app/v6_preview_app.dart`（挂 debugPrint 覆盖）
- `lib/app/pages/plugin_page.dart`（诊断面板入口）
- `lib/app/shell/…` 设置入口（看现有设置页在哪）
- `test/app/app_log_test.dart`（新）

## 依赖

- 前置任务：无
- 需要裁决：无（纯读，不写用户数据）

## 验收

- 机器判定：`app_log_test.dart` 覆盖「环形丢弃最旧」「按 tag 过滤」「格式化含时间戳」
- 人判定：模拟器上打开插件页 → 点诊断 → 看到版本/权限 → 复制成功；设置里能看到日志
- 验收清单：`docs/acceptance/2026-11-17-diagnostics.md`（完成后补）

## 风险

- 契约：无（不改契约）
- 数据：无（只读内存）
- 发布：需要发版才到用户手上
- 真机：无特殊

## 交接区

### 已完成

- `lib/core/diagnostics/app_log.dart`：环形缓冲（800 条）+ 接管 `debugPrint`。
  不落盘、不上报；`add` 里刻意不调 `debugPrint`（会递归）。
- `lib/app/pages/diagnostics_page.dart`：两种模式 —— 全量（设置进）/ 单插件（插件页进）。
  插件模式先按 tag（plugin / query-host / bridge）捞，再补"正文提到 pluginId"的行。
- `lib/app/pages/plugin_page.dart`：AppBar 加诊断入口。
- `lib/app/pages/settings_page.dart`：「关于」组加「诊断与日志」。
- `lib/main.dart` + `lib/main_v6_preview.dart`：启动即 `AppLog.install()`。
- `test/app/app_log_test.dart`：9 条（tag 推断 / 环形丢弃 / 前缀过滤 / limit 顺序 / dump 格式）。

### 下一步

- 复制出来的内容没有版本号。贴给他人时还得自己说"我是 6.1.11"。
  要加就再走一次 `PackageInfo`（异步），别在日志里写死版本常量。
- 日志目前只有内存一份，重启即lost。真要长期排查得落盘轮转，但这轮先解决"看得见"。

### 已知坑

- `debugPrint` 覆盖必须在 `runApp` 之前，否则启动阶段的日志抓不到。
- 两个页面都是 push 上来的，但 shell 的底栏仍然压在下面 → ListView 底部 padding
  必须留够（96），否则最后一行点不到。改之前「诊断与日志」那行就是点不中的。
- 插件诊断的日志过滤别只按 tag：`plugin/page` 这类日志的正文里才带插件 id。

### 已知坑/失败尝试

- 2026-11-16 排查插件问题时，错误只进 `debugPrint` → logcat，界面上完全看不见，
  用户只能描述"点了没反应"。这是本任务的直接动因。

### 未验证

- 清空日志的确认弹窗（代码直白，没点）
- 真机上日志量很大的时候滚动性能（模拟器 12 条，看不出问题）
