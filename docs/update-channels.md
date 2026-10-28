# 更新清单：一个仓库一份，V5 / V6 各自独立

> 2026-10-28 **重写**。原版（2026-10-27）是按"同一仓库放两份清单
> （`update.json` + `update_v6.json`）"写的，那个方案**没有落地**，
> `update_v6.json` 这个文件在本仓库从未存在过（`git log --all` 查过）。
> 现在以代码为准重写，别再照旧版发版。

## 1. 现状

| 线 | 仓库 | 清单 | 本地状态前缀 |
|---|---|---|---|
| V6 | `Aria-2676/taskmaster-v6`（本仓库） | 仓库根 `update.json` | `v6`（`app_update_v6_*`） |
| V5 | `Aria-2676/note_study` | 那边自己的 `update.json` | 无（`app_update_*`） |

- 清单文件名在代码里：`AppUpdateService.defaultManifestPath = 'update.json'`。
- 候选地址全部指向本仓库的 `main`（`lib/core/config/cdn_bases.dart`）：
  `gcore` / `testingcf` / `cdn` 三个 jsDelivr 节点 + `raw.githubusercontent.com`
  + GitHub Contents API（`contentsApiBase` 里写死 `Aria-2676/taskmaster-v6`）。
- **两份清单同名但不是同一个文件**：它们在两个仓库里，互不影响。

## 2. 为什么最后没用「同仓库两份清单」

原方案的理由是：V5 已发布包的清单地址在代码里写死，改不了，
所以只能让 V6 换名 `update_v6.json` 来避开。

后来 V5 独立成仓库（`note_study`，冻结在 5.5.26），**两边物理隔离**了，
同名的好处反而更大：V6 一行候选地址都不用改，`publish_release.ps1`
也不用加"我要改哪份清单"的参数。于是 `update_v6.json` 这个中间产物被丢掉。

> 记住这条的实用价值：以后在任何文档里看到 `update_v6.json`，
> 那是 10-27 方案的残留，直接改成 `update.json`。

## 3. 本地状态仍然要隔离

两边同包名、共用一份 SharedPreferences。冲突里最狠的是**资源包构建号**：

```
V5 应用过资源包 build 5  →  app_update_asset_build = 5
V6 读到 5                →  以为自己也应用过，静默跳过 build 5 的 V6 资源
                         →  而且下次还读到 5，永远不会补
```

所以 `UpdateChannel.current` 的 `settingsScope` 是 `'v6'`，把九个键全加前缀。
"跳过版本""关闭提醒""上次检查时间"也一起隔离：用户在 V5 里静音过更新，
不代表他愿意在 V6 里也被静音。

空 scope 生成的键名与 V5 完全一致，已发布包的行为一个字都没变。

## 4. 发 V6 新版本

1. `pubspec.yaml`：`6.x.y+<递增的 build>`（versionCode 只能涨）
2. `tool/build_apk.ps1`（split ABI），记下每个包的 `sha256` 与 `sizeBytes`
3. 产物传 GitHub Release —— **APK 必须走 Releases**：jsDelivr 单文件上限 20MB，
   包是 21~62MB，走 jsDelivr 必 403
4. **最后**改 `update.json`：`latest.version` + `downloads`（`url` / `sha256` / `sizeBytes`）
5. 刷 jsDelivr 缓存（清单在 `@main` 上，不刷会读到旧缓存）

顺序不能反：先改清单后传包，用户点下去就是死链，而且不会点第二次。
`downloads` 留空是安全的中间态——客户端判定为"无更新"，不报错。

## 5. 发 6.0.0（唯一一次跨仓库联动）

1. 同上 1–3，包挂在 V6 仓库的 Release 上
2. 改**本仓库** `update.json` → `6.0.0` + 产物信息
3. 改**V5 仓库**（`note_study`）的 `update.json` → `latest.version = 6.0.0`，
   `minSupported` 保持 `5.0.0`
4. 更新说明里必须写：**V5 的任务与积分不会出现在 V6 里**

`minSupported` 永远不能提到 6.0.0：提了就是强制更新，"跳过此版本"失效，
用户失去拒绝的权利。`test/core/updater/update_manifest_guard_test.dart` 有断言挡这条。

## 6. 还没做

- **后台检查**：V5 有 WorkManager 周期任务；V6 目前只在启动时检查一次，
  长时间不打开就收不到提示（回前台的重试由 `AppUpdatePromptHost` 负责，
  进程被杀就没有了）。
- **灰度**：没有分批放量，清单改了就是全量。
- **更新说明的展示**：`update.json` 里写了 `notes`，但页面只在有更新时才显示
  说明卡片，正在用的版本看不到"我在用的是什么版本"。

> 一条踩过的坑（2026-10-27 实测）：`AppUpdateProvider` 一开始被包在
> `MaterialApp.home` 里，`Navigator.push` 出来的版本页读不到它，点「关于」
> 直接红屏。Provider 的作用域是**祖先链**，而路由的祖先链里没有 home 子树。
> `test/core/updater/update_page_scope_test.dart` 专门锁这条，且已验证
> "去掉 Provider 会立刻变红"。
