# 2026-10-27 验收：更新渠道一分为二

> ⚠️ **清单文件名部分已失效**：本单写的是 V6 用 `update_v6.json`，那个方案没落地。
> 现状是「一个仓库一份 `update.json`」，见 `docs/update-channels.md`（2026-10-28 重写）。
> 本单其余内容（本地状态隔离 `settingsScope: 'v6'`、Provider 作用域）仍然有效。

按「6.0.0 是一次引流，之后 V5/V6 各自维护」做的改动。

| 改动 | 文件 |
|---|---|
| 渠道定义（清单 + 本地状态成对） | `lib/core/updater/update_channel.dart`（新） |
| service 支持自定义清单名 | `app_update_service.dart` |
| 本地状态支持键前缀 | `app_update_settings.dart` |
| V6 走自己的渠道 | `v6_preview_app.dart` `_startUpdater` |
| V6 的清单 | `update_v6.json`（新） |
| 防误改 | `test/core/updater/update_manifest_guard_test.dart`（新） |

---

## 零、已自测（不用你动手）

`flutter test` 全量 **1145 条通过**（新增 15 条）；`flutter analyze lib` 无 error/warning。

| # | 断言 | 位置 |
|---|---|---|
| S1 | 两条渠道读不同清单：`update.json` / `update_v6.json` | `update_channel_test` 渠道定义 |
| S2 | V5 渠道本地状态前缀为空，V6 为 `v6` | 同上 |
| S3 | `createService()` 出来的 service 记住自己的清单名 | 同上 |
| S4 | 所有候选地址都以 `update_v6.json` 结尾（CDN 全挂也不会退到 V5 清单） | 候选地址跟着清单名走 |
| S5 | Contents API 兜底地址按清单名生成 | 同上 |
| S6 | 默认 service 仍读 `update.json`（老调用点行为不变） | 同上 |
| S7 | 空前缀写的是 `app_update_ignored_version`，一个字符没变 | 本地状态隔离 |
| S8 | v6 前缀写自己的键，与 V5 互不覆盖 | 同上 |
| S9 | **资源包构建号互不影响**（V5 应用过 build 7，V6 仍读到 0） | 同上 |
| S10 | V5 关掉提醒不影响 V6（V6 仍为开启） | 同上 |
| S11 | `update.json` 的 `minSupported` 主版本 ≤ 5（不能变强制更新） | 清单守卫 |
| S12 | `update.json` 的 `latest.version` ≤ 6.0.0（V5 渠道冻结） | 同上 |
| S13 | 两份清单 `schemaVersion` 一致 | 同上 |
| S14 | `update_v6.json` 指向的版本 ≤ `pubspec` 版本（不能指向还不存在的包） | 同上 |
| S15 | `downloads` 里只要有产物就必须带 url + 64 位 sha256 + sizeBytes | 同上 |
| S16 | 「关于」有构造器时能打开；没有时只提示不崩 | `mode_switcher_test` |
| S17 | 从「关于」push 到版本页不报 `ProviderNotFoundException` | `update_page_scope_test` |
| S18 | 上一条**已验证有效性**：去掉 Provider 后立刻变红 | 手动破坏后跑过一次 |

---

## 一、真机实测（本轮额外发现并修掉的）

原本只做了"接更新器"，实测点「关于」直接红屏 `ProviderNotFoundException`：

| 项 | 结果 |
|---|---|
| 原因 | `AppUpdateProvider` 被包在 `MaterialApp.home` 里。`Navigator.push` 的路由祖先链里没有 home 子树，读不到 |
| 修法 | Provider 提到 **MaterialApp 外**；`AppUpdatePromptHost` 留在 **MaterialApp 内**（它要 showDialog，需要 Navigator） |
| 修复后 | 「我的 → 关于」→ 标题「关于」、当前版本 **6.0.0**、检查更新（已是最新版本）、两个开关、更新统计 |
| 截图 | `i3-about.png` |
| 回归测试 | `update_page_scope_test.dart`，并已用"去掉 Provider"验证过它会变红 |

## 二、需要你决定的一件

| # | 问题 | 现状 | 选项 |
|---|---|---|---|
| A1 | V6 只在**启动时**检查一次更新（V5 有 WorkManager 周期任务） | 长期不打开就收不到提示；回前台会重试，但进程被杀就没有 | a) 先这样；b) 补后台周期检查 |

我倾向 a：不影响"能不能更新"，只影响"提示得勤不勤"。

---

## 三、发布纪律（做的时候照着走）

### 发 6.0.0（唯一一次跨线）

1. `pubspec` 已是 `6.0.0+6000`
2. `flutter build apk --release`，确认签名是 `D:\Dev\keystore\` 那把
3. 4 个产物传 GitHub Release，记下 `sha256` / `sizeBytes`
4. `update_v6.json`：填 `downloads`
5. `update.json`：`latest.version` → `6.0.0` + 同一份 `downloads`，**`minSupported` 保持 `5.0.0`**
6. 更新说明写明：V5 的任务不会出现在 V6 里

### 之后每次发 V6

只改 `update_v6.json`。`update.json` 一个字都不动。

---

## 四、没验证的

| 项 | 为什么 | 什么时候验 |
|---|---|---|
| 更新弹窗真的会弹 | 本地 6.0.0 已是清单里的版本 | 发版时用旧包装上，清单写更高版本 |
| 引流弹窗的文案效果 | 要真实设备看 | 同上 |
| 签名指纹一致 | 只能构建后比对 | `apksigner verify --print-certs` |

---

## 签收

| 日期 | 结果 | 不过的编号 | 备注 |
|---|---|---|---|
| | | | |
