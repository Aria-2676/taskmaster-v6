# 能力与版本对照

> 最后更新：2026-11-01

插件能做什么，取决于**装着它的那版主包提供了什么能力**。这张表是唯一对照源：
插件作者查它决定 `host` 写什么，主包开发者加能力时同步补一行。

## 1. 怎么用这张表

插件在 `plugin.json` 里声明它需要的**最低 App 版本**：

```json
{ "host": ">=6.1.0" }
```

- 低于这个版本的主包：市场里标灰并写「需要 App >=6.1.0」，**装不上**。
- 这是**合理事实**，不是缺陷：能力没做出来之前，插件装了也只能报错。
- 不写 `host` = 不限制（老插件都是这样）。

`contract` 与 `host` 分工：

| 字段 | 回答什么问题 | 什么时候动 |
|---|---|---|
| `contract` | 接口还兼不兼容 | 破坏性改动才 +1；**新增**方法不 +1（见 §4） |
| `host` | 至少要哪个 App 版本 | 插件作者自己写，精确到补丁号 |

## 2. 能力矩阵

| App 版本 | 新增能力 | 谁在用 |
|---|---|---|
| **6.0.0** | `system.info`；`task.count/list/create/update/setDone/delete`；`tag.list`；`event.pending/ack`；`db.insert/select/update/delete/aggregate`；`store.get/set/remove`（插件私有 KV）；`currency.get/set`；4 个区域插槽；钩子 `task.completed` / `task.recycled` / `task.restored`；页面级整页插件；首页模式（`home`） | 全部现有插件 |
| **6.1.0** | `timer.start/state/pause/resume/reset/skip/next/history`；`notify.show/schedule/cancel`；钩子 `pomodoro.sessionFinished` 真正派发 | 番茄钟插件 |

> 表格只记**新增了什么**，不重复列旧能力 —— 想知道某版本能干什么，从上往下累加。

## 3. 单条能力的细节（按需查）

| 能力 | 参数 | 返回 | 备注 |
|---|---|---|---|
| `timer.start` | `mode?`（`focus`/`short_break`/`long_break`）、`taskId?` | `{sessionId, mode, plannedSeconds, remainingSeconds}` | 同一时刻只有一个会话 |
| `timer.state` | — | `{running, mode, remainingSeconds, plannedSeconds, round}` 或 `null` | 插件页面每次打开都要调它 |
| `timer.pause` / `timer.resume` / `timer.reset` | — | 同 `timer.state` | 暂停期间不计入有效时长 |
| `timer.skip` | — | 同 `timer.state` | 提前结束，照常派发钩子 |
| `timer.next` | — | 同 `timer.state` | 进入下一阶段**并开跑**（第 4 个专注后是长休） |
| `timer.history` | `limit?`（1~200，默认 50）、`since?`（ISO8601） | `{sessions: [{sessionId, mode, durationSeconds, actualSeconds, endedAt, taskId?}]}` | 已结束会话，**最近的在前**。这是记录的数据源，别用钩子补发去攒 |
| `notify.show` | `title`、`body`、`channel?`（`pomodoro`/`plugin`） | `{ok}` | 即时通知，需 `notify:local` 权限 |
| `notify.schedule` | `title`、`body`、`afterSeconds`、`channel?` | `{result: 'exact'\|'inexact'\|'denied'}` | **不保证准时**：系统拒精确闹钟时返回 `inexact` |
| `notify.cancel` | `id` | `{ok}` | 取消由插件排的通知 |

## 4. 契约版本怎么涨

- **新增**方法/权限/钩子/插槽 → `contract` **不涨**，在 §2 表里记一行即可（老插件不读它，照旧工作）。
- **改**已有方法的参数/返回值语义 → 必须 +1，并在 `docs/plugin-contract.md` 写迁移说明。
- 唯一例外（历史遗留）：6.1.0 为了挡住 6.0.x，`current` 从 1 涨到了 2 —— 因为
  6.0.x 不认识 `host`，只认 `contract`。**之后不再靠 contract 表达版本门槛**，
  它回归「兼不兼容」这一个含义。

## 5. 加能力时的检查清单

1. 方法名按 `<域>.<动作>`，域用已存在的（`task` / `db` / `event` / `currency` / `timer` / `notify`），
   新域要先在 `docs/conventions/architecture.md` 的单据里登记。
2. 权限名同步 `PluginManifest.knownPermissions` + `PermissionCopy` + `docs/plugin-contract.md`。
3. §2 表补一行，§3 补参数细节。
4. 在 `docs/ai/work/` 的任务文件里写清"这是新增还是破坏性改动"。
