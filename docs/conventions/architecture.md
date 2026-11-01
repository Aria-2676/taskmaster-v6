# 架构与边界

> 最后更新：2026-11-01

## 1. 两层结构

| 层 | 目录 | 放什么 | 判断方法 |
|---|---|---|---|
| 主包外壳 | `lib/app/` | 页面、状态、路由、装配、插件桥接的**应用实现** | 只服务本 App 的界面与组装 → app |
| 能力层 | `lib/core/` | 数据、更新器、插件运行时、扩展位框架、备份、纯函数 | 这段逻辑能不能在**别的 App** 里复用？能 → core |

**依赖方向**：`lib/app/` 可以依赖 `lib/core/`，**反过来不行**。
`lib/core/` 不得 import `lib/app/`。需要 app 数据时，core 定义接口/异常，由 app 注入实现。

例：`PluginBridge` 放在 `lib/app/data/`，因为它要用 `TaskRepository`；
插件清单/索引/安装器在 `lib/core/plugin/`，它们不认识界面。

## 2. 代码放哪（判据）

| 目录 | 放什么 |
|---|---|
| `lib/core/data/` | v6 schema、dbVersion、迁移链、插件表物化 |
| `lib/core/plugin/` | manifest、index、installer、store、event journal、权限文案 |
| `lib/core/extension/` | 插槽、钩子、货币框架、入口注册 |
| `lib/core/updater/` | 清单、渠道、下载、安装器、版本页 |
| `lib/core/backup/` | 备份格式、收集、打包、恢复 |
| `lib/core/field/` | 任务字段声明与偏好解析 |
| `lib/app/shell/` | 主壳、侧边栏、入口清单、装配 |
| `lib/app/pages/` | 具体页面 |
| `lib/app/state/` | TaskStore / FieldStore / HomeModeStore / PluginMarketStore / CurrencyStore |
| `lib/app/data/` | Repository、PluginBridge、索引加载、备份仓储 |
| `plugins/src/<id>/` | 插件源码（`plugin.json` + HTML/JS/资源） |
| `plugins/packages/<id>_v<ver>.zip` | 仓库分发产物，**不打进 APK** |
| `assets/plugins/index.json` | 随包货架索引，**唯一随包的插件文件** |

## 3. 数据边界

- **主包表**：`tasks` / `recycled_tasks` / `tags` / `task_tags` / `settings`。
- **基础设施表**：`plg_migrations` / `installed_plugins` / `plugin_events`。
  它们不属于任何业务，不加 `plg_` 前缀。
- **插件表**：只能 `plg_<id>_<suffix>`，由 manifest 的 `storage` 声明；
  插件永不碰主包表，宿主永不执行插件传来的 SQL。
- **列名一律用常量**（`TaskCol` / `V6Table` / `SettingsKeys` 等），SQL 里不出现裸字符串。
- **迁移**：`if (newVersion > version) throw`；`if (oldVersion < N)` 补一步，
  不用 `if (old == N)`。每条迁移必须有“造一个真老库再打开”的测试。
- **删除**：删除类 API 不留默认值（如 `delete(id, {required bool toRecycle})`），
  防止“忘了传”悄悄留垃圾。插件删除跟随用户的回收站设置，插件不能自己决定彻底删。
- **外部数据 fail-soft**：清单/索引等外网数据，顶层结构不对 → 抛；单字段非法 → 丢该字段，
  其余可用。程序错误（如版本超出认知）→ 直接失败。

## 4. 扩展位（三级，按风险从低到高）

| 级别 | 载体 | 插件能给什么 | 主包负责什么 |
|---|---|---|---|
| 页面级 | WebView 整页 | 整个页面 HTML/JS | 外壳（底栏/侧边栏/顶栏）、入口、生命周期 |
| 区域级 | 4 个插槽（`SlotId`） | **只给数据/文本/枚举** | 字体、颜色、间距、圆角、排版 |
| 服务级 | 白名单实现（目前仅 `currency.earnPolicy`） | 换算法 | 账本/表结构/互斥与回退 |
| 事件钩子 | `HookId` | 订阅通知 | 派发与超时隔离 |

**硬规则**

- 区域级插槽 **A 档**：插件不能返回 HTML/CSS/颜色/字号；类型不符视为无效。
- 钩子是**通知不是拦截**：插件不能取消操作；单个监听器超时 500ms 或报错 → 记日志继续，
  绝不让插件阻塞任务完成。无人订阅时主流程必须完整可用。
- 同一插槽多个提供者：按注册顺序取第一个有效值，其余忽略；服务级同一时刻只能一个生效。
- **外壳永远不交给插件**：插件崩了用户必须有路可退（首页熔断三件套）。
- 新增插槽/钩子/服务必须同时改 `docs/plugin-contract.md`，并判断契约版本是否 +1。

## 5. 单一判据

同一语义只允许一个判据，避免“四处各过滤一次，漏一处就出错”。

| 语义 | 唯一判据 |
|---|---|
| 入口有哪些、在哪出现 | `AppDestination` |
| 任务字段有哪些、顺序/默认值 | `FieldCatalog` + `FieldPrefs` |
| 插件能不能装 | `PluginManifest` + `PluginContract` |
| 插件对外是否可见（入口/首页/货币位） | `PluginMarketStore.active` |
| 首页是内置还是插件 | `HomeMode` |
| 当前货币提供者 | `CurrencyStore.providerId`（空串要归一化成 null） |
| 设置键名 | `SettingsKeys` |
| 权限的人话文案 | `PermissionCopy` |
| 钩子 payload | `Task.toHookPayload()` |

新增一个“状态”时，先问：**它是不是已经有判据了？** 有就复用，不要新建第二个。

## 6. 错误与日志

- **不要用文案盖住原始错误。** 能拿到异常/堆栈就露出原文（截断即可），
  例如插件市场空态显示 `indexError`，不要只写“索引没取到”。
- 失败要能定位：错误信息里带插件 id / 表名 / 文件路径 / 操作名。
- 日志前缀：`[plugin]`、`[repo]`、`[update]`、`[backup]` 等；不要静默 `catch`。
- 允许“失败也继续”的场景必须写明：最坏结果是什么、下一次怎么自愈（如 reconcile）。
- 对外返回值固定：bridge 成功 `{ok:true,result}`，失败 `{ok:false,error:{code,message}}`；
  **失败不抛异常**，让插件只看 `ok`。

## 7. 安全与隐私

- 仓库是公开的：**token、密钥库、口令、真实用户数据绝不入库**。
  `.gitignore` 是纵深防御，提交前还要 `git status --untracked-files=all` 复验。
- 插件 `id` 只允许 `[a-z][a-z0-9_]{1,31}`（会成为目录名和表前缀）；
  `entry`/包路径拒绝 `..`、绝对路径、反斜杠；下载后必须验 sha256。
- 插件权限默认空集，读/写/删三条分开；未声明 → `permission_denied`，不静默。
- 插件数据只能落自己的 `plg_<id>_*` 表和 `plg.<id>.*` KV；不能指向主包表。
- 密钥库与口令是**一对**：备份 `.jks` 必须同时备份口令，但备份包本身等同钥匙，绝不入库。

## 8. 性能与资源

- 列表/查询必须有上限（`limit`/`cursor`），不允许“全量拉取”。
- 不在小区域塞 WebView；不做常驻隐藏 WebView（几十 MB、被杀补不回来）。
- 插件事件用“落库 + 补发”，不靠常驻进程。
- 统计/聚合必须走索引或构造式查询，不把全表拉回内存算。
- 启动路径只做必要的事；清理类工作机会式触发（启动/改设置/进页面），不常驻调度器。

## 9. 改动前的自问

1. 这段逻辑属于 core 还是 app？会不会反向依赖？
2. 有没有现成的单一判据可以复用？
3. 改的是数据/契约/发布链路吗？如果是，决策记录和验收清单在哪？
4. 插件能不能提供主包没有的东西？不能就放设置，不要包装成插件。
5. 失败时用户看到什么、我从哪里能定位？
