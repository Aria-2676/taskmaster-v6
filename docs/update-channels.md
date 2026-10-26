# 更新渠道：V5 与 V6 各自维护

> 2026-10-27 ｜ 状态：**已实现**（`lib/core/updater/update_channel.dart`、`update_v6.json`）

## 1. 一句话

6.0.0 是 V5 唯一一次看到 V6 的机会，**之后两条线彻底分开**：
V5 停在自己的清单上，V6 只认自己的清单。谁发版都不会打扰另一边。

| 渠道 | 清单 | 本地状态前缀 | 谁在用 |
|---|---|---|---|
| v5 | `update.json` | 无（`app_update_*`） | 所有已发布的 5.x 包 |
| v6 | `update_v6.json` | `v6`（`app_update_v6_*`） | 6.0.0 及之后 |

清单地址在 V5 的代码里是写死的，改了就断供 —— 所以**只能让 V6 换文件名**，
反过来不成立。

## 2. 引流规则：可选，不可强制

V5 用户会在更新弹窗里看到 6.0.0，三个选择：

| 动作 | 结果 |
|---|---|
| 立即更新 | 下载 6.0.0，覆盖安装，此后走 V6 渠道 |
| 稍后 | 本次不更，下次检查还会提示 |
| 跳过此版本 | 记进 `app_update_ignored_version`，**不再提示**（V5 已有此功能） |

**因此 `update.json` 的 `minSupported` 永远不能提到 6.0.0。**
提了就是强制更新，"跳过此版本"会失效，用户失去拒绝的权利。
`test/core/updater/update_manifest_guard_test.dart` 有断言挡这一条。

## 3. V5 清单冻结

发完 6.0.0 之后，`update.json` 只做一件事：继续把 5.x 用户送到 6.0.0。

- `latest.version` **停在 6.0.0**，不再涨（涨了就是两条线又合并）
- `minSupported` 保持 `5.0.0`
- `assets`（资源热更）也一并冻结 —— V5 的界面不会再改，没必要热更

守卫测试同样断言 `latest.version ≤ 6.0.0`。

## 4. 本地状态为什么必须隔离

两边是同包名，共用一份 SharedPreferences。冲突里最狠的是**资源包构建号**：

```
V5 应用过资源包 build 5  →  app_update_asset_build = 5
V6 读到 5                →  以为自己也应用过，静默跳过 build 5 的 V6 资源
                         →  而且下次还读到 5，永远不会补
```

所以 `AppUpdateSettings(scope: 'v6')` 把九个键全部加前缀。
"跳过版本""关闭提醒""上次检查时间"也一起隔离：用户在 V5 里静音过更新，
不代表他愿意在 V6 里也被静音 —— 换了个应用形态，值得重新问一次。

空 scope 生成的键名与 V5 完全一致（`app_update_ignored_version` 等），
已发布包的行为一个字都没变。

## 5. 发布流程

### 发 V6 新版本（常态）

1. `pubspec.yaml`：`6.x.y+<递增的 build>`
2. `flutter build apk --release`，确认签名是 `D:\Dev\keystore\` 那把
3. 产物传 GitHub Release，记下 `sha256` 与 `sizeBytes`
4. **最后**改 `update_v6.json`：`latest.version` + `downloads`
5. `update.json` 一个字都不要动

### 发 6.0.0（唯一一次跨线）

1. 同上面的 1–3
2. `update_v6.json` → `6.0.0` + 产物信息
3. `update.json` → `latest.version` 改成 `6.0.0` + 产物信息，`minSupported` 保持 `5.0.0`
4. 更新说明里必须写：**V5 的任务不会出现在 V6 里**

顺序不能反。先改清单后传包，用户点下去就是死链，而且不会点第二次。

## 6. V6 侧做了哪些适配

| 项 | 做法 |
|---|---|
| 清单地址 | `UpdateChannel.v6.createService()` → `update_v6.json`，候选地址与 Contents API 兜底都跟着改名 |
| 本地状态 | `UpdateChannel.v6.settings` → 键前缀 `v6` |
| 入口 | `main.dart` 只传 `checkUpdate: true`；渠道选择收在 `V6PreviewApp` 里，预览入口默认不联网 |
| 弹窗 | 复用 V5 的 `AppUpdatePromptHost` / `AppUpdateDialog`（Material 3，与 V6 观感一致） |
| 手动入口 | 「我的 → 关于」→ `AppUpdatePage`（标题改为"关于"）。**这个入口不能省**：自动提示被跳过或被关掉之后，它是唯一的反悔路径 |
| Provider 层级 | `AppUpdateProvider` 必须包在 **MaterialApp 外**，`AppUpdatePromptHost` 在 **MaterialApp 内**。放反了表现为点「关于」直接 `ProviderNotFoundException` 红屏 |
| 强更 | `update_v6.json` 的 `minSupported` 目前 `6.0.0`（等于不强制）；将来要强更老 V6 时改它 |

## 7. 还没做

- **V6 的后台检查**：V5 有 WorkManager 周期任务；V6 目前只在启动时检查一次。
  长时间不打开就收不到提示（回前台的重试由 `AppUpdatePromptHost` 负责，
  但进程被杀就没有了）。
- **灰度**：没有分批放量的机制，清单改了就是全量。
- **更新说明的展示**：`update_v6.json` 里写了 `notes`，但 V6 的页面只在有更新时
  才显示说明卡片，正在用的版本看不到"我在用的是什么版本"。

> 一条踩过的坑（2026-10-27 实测）：`AppUpdateProvider` 一开始被包在
> `MaterialApp.home` 里，`Navigator.push` 出来的版本页读不到它，点「关于」
> 直接红屏。Provider 的作用域是**祖先链**，而路由的祖先链里没有 home 子树。
> `test/core/updater/update_page_scope_test.dart` 专门锁这条，且已验证
> "去掉 Provider 会立刻变红"。
