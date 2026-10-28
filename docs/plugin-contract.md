# 插件契约 v0.1（骨架，逐条待确认）

> 2026-10-22 ｜ 与 `main-package.md` 配套
> 这六件是**与实现技术无关**的规格：无论最终走 Flutter+WebView 还是别的载体，
> 包格式、版本、数据边界、插槽、入口、分发都不变。先定这些，再谈写代码。

---

## 1. 包格式

一个插件 = 一个 zip。解压后目录结构：

```
<plugin-id>/
  manifest.json          必需
  index.html             页面型插件必需（入口）
  assets/                任意静态资源
  data/                  可选，初始数据（首次安装时导入插件表）
```

`manifest.json`（字段固定，多一个少一个都会导致安装失败）：

```json
{
  "id": "pomodoro",
  "name": "番茄钟",
  "version": "1.0.0",
  "contract": 1,
  "host": ">=6.0.0 <7.0.0",
  "kind": "page",
  "entry": "index.html",
  "icon": "assets/icon.png",
  "sizeBytes": 123456,
  "sha256": "…64位…",
  "permissions": ["task:read", "points:read"],
  "slots": [],
  "hooks": ["task.completed"]
}
```

- `id`：全局唯一、小写、`[a-z0-9-]`，装上后不可改
- `kind`：`page`（整页）｜`slot`（只供插槽数据）｜`theme`（主题包）｜`asset`（纯资源）
- `permissions`：白名单里的能力名，未声明就调用 → 直接拒绝并记日志
- `slots` / `hooks`：本插件要占用的插槽与要订阅的事件

---

## 2. 契约版本

**不用 app 版本号做兼容判断，用 `contract` 整数。**

- 宿主声明：`supportedContract = 1`
- 插件声明：`"contract": 1`
- 判定规则：
  - `plugin.contract > host.supportedContract` → **拒绝安装**，提示"需要更新 App"
  - `plugin.contract <= host.supportedContract` → 允许安装
  - `host` 字段是第二道保险（判断具体版本区间），只在必要时用

**什么情况要升 `contract`**：变了插槽的数据结构、变了权限名、变了 API 签名。
只是主包加了个页面、改了任务页交互 → **不升**。这条是让插件不必跟着每次发版重打的唯一办法。

**`system.info` 回的 `version` 是给插件页显示用的**：版本号只能由宿主给
（取自包内 `plugin.json`），插件**不许在 HTML 里写死**——写死的话升级后页面上
还是旧版本号。加这个字段只是加返回值，不改任何入参，所以不必升 `contract`；
老插件不读它，照旧工作。

`contract` 也一并回，但**不建议回显给用户**：它是接口兼容版本，用户改不了也
看不懂，只在"插件装不上"时才有意义（那件事由市场页和安装报错说）。取舍见
`docs/decisions.md`「契约版本给机器看，不给用户看」。

---

## 3. 数据 API

插件**永远不直连数据库**，只走宿主的 JS bridge。第一版只开放这些：

| 命名空间 | 方法 | 权限 |
|---|---|---|
| `task` | `list(dateRange)` / `get(id)` / `count(filter)` | `task:read` |
| `task` | `complete(id)` / `add(obj)` / `update(id,obj)` | `task:write` |
| `points` | `balance()` / `records(limit)` | `points:read` |
| `points` | `add(n, reason)` / `spend(n, reason)` | `points:write` |
| `tag` | `list()` | `tag:read` |
| `settings` | `get(key)` / `set(key,val)`（自动加 `plg.<id>.` 前缀） | 无（隔离） |
| `store` | `get/set/remove(key)`（插件私有 KV） | 无（隔离） |
| `system` | `notify(...)` / `vibrate()` / `schedule(...)` | `system:notify` |

**权限声明**：manifest 里 `permissions: ["task:read"]`，**不声明就拿不到数据**（默认空集）。
宿主不认识的一律忽略（向前兼容）。

读、写、删是**三条独立的权限**，不给"写就顺便能删"的方便：

| 权限 | 给什么 | 为什么单独拆 |
|---|---|---|
| `task:read` | `task.count` / `task.list` / `tag.list` | — |
| `task:write` | `task.create` / `task.update` / `task.setDone` | 改错能改回来 |
| `task:delete` | `task.delete` | 不可逆；不能和"改标题"共用一个开关 |

**已落地的方法**（`lib/app/data/plugin_bridge.dart`）：

| 方法 | 参数 | 返回 |
|---|---|---|
| `system.info` | — | `{pluginId, version, contract, permissions}` |
| `task.count` | `date` 或 `from`+`to` | `{from, to, total, done}` |
| `task.list` | `from`+`to`+`limit`(≤200) | 裁剪过的任务数组（不含 description） |
| `task.create` | `title`（必填）、`date`、`priority`、`estimatedMinutes`、`description`、`tagIds` | `{id}` |
| `task.update` | `id` + 任意可改字段（**只改传了的**） | `{id, updated}` |
| `task.setDone` | `id`、`done`(bool) | `{id, isDone}` |
| `task.delete` | `id` | `{id, deleted, toRecycle}` |
| `tag.list` | — | `[{id, name}]` |
| `store.get/set/remove` | `key`(+`value`) | 插件私有 KV，自动加 `plg.<id>.` 前缀 |

写接口的三条约定：

1. **入参一律当不可信输入**：类型不对直接 `bad_params`，不做宽松转换。
   `title` ≤200 字、`description` ≤2000 字、`estimatedMinutes` 1~1440 或 null、
   `priority` 只收五个值、`date` 必须是 `yyyy-MM-dd` 且能原样还原、`tagIds` 必须真实存在。
2. **`task.update` 是部分更新**：没传的字段不动；显式传 `null` 才是清空。
   这和主包编辑页"整表覆盖"是两套语义，混用会把用户没碰的字段清掉。
3. **删除跟随用户设置**：开着回收站就进回收站，插件说了不算 ——
   否则等于给了插件一个绕过保护的口子。

写成功后会回调宿主刷新（`PluginBridge.onChanged`），
否则会出现"插件里加了一条，退出插件首页还是旧的"。

**硬规则：**
1. 每个方法都是异步、幂等语义明确、失败返回错误码而不是抛异常
2. 返回的是**快照**，不是可写引用
3. 插件自己的数据只能落在 `plg_<id>_*` 表和私有 KV，绝不碰主包表
4. 数据量大的一律分页（`limit`/`cursor`），不允许"全量拉取"

### 3.5 插件私有存储（B 方案：声明的表）

插件要存自己的内容（日记正文、笔记条目、统计数据），在 `plugin.json` 里声明表结构：

```json
"storage": {
  "version": 1,
  "tables": [
    {
      "name": "entries",
      "columns": [
        {"name": "day", "type": "text", "notNull": true},
        {"name": "body", "type": "text"},
        {"name": "minutes", "type": "integer"}
      ],
      "unique": [["day"]],
      "indexes": [["minutes"]]
    }
  ]
}
```

- 层名成 `plg_<id>_entries`；`id` 由宿主加，插件**不要声明**（会撞名）
- 类型只有 `text` / `integer` / `real`；**没有 blob**，也没有裸 SQL 片段
- 一个插件最多 8 张表、每表 24 列；表名/列名只允许小写字母数字下划线（≤32）
- 建表在安装时和每次启动时各做一次（内存注册表冷启动是空的，靠 `ensureSchemas` 补）

读取用**构造式查询**，永远不执行插件传来的 SQL：

| 方法 | 参数 |
|---|---|
| `db.insert` | `table`, `values` → `{id}` |
| `db.select` | `table`, `columns?`, `where?`, `orderBy?`, `limit?`(≤500, 默认 100), `offset?` |
| `db.aggregate` | `table`, `groupBy?`, `metrics[{fn, column, as}]`, `where?` |
| `db.update` | `table`, `values`, `where`（**必须带**）→ `{updated}` |
| `db.delete` | `table`, `where`（**必须带**）→ `{deleted}` |

`where` 是数组，每项 `{column, op, value}`；`op` 白名单：
`=` `!=` `<` `<=` `>` `>=` `like` `in` `isNull` `notNull`。
`metrics.fn` 白名单：`count` `sum` `avg` `min` `max`。

```js
// 按天统计专注时长
const rows = await window.host.call('db.aggregate', {
  table: 'entries',
  groupBy: ['day'],
  metrics: [{ fn: 'sum', column: 'minutes', as: 'total' }],
});
```

**为什么不用"通用集合表 + JSON"**：统计要按维度聚合，JSON 只能全量拉回内存算，
数据一多就废。让插件声明真实列，`GROUP BY` 和索引才用得起来。

**为什么不能给任意 SQL**：本地库里是用户唯一的一份数据。一个 `DROP TABLE tasks`
就够了。所以表名/列名只能来自 manifest 声明，值全部参数化，
`update`/`delete` 不带条件直接拒绝。

错误码：`no_storage`（没声明 storage 却调 db.*）、`bad_params`（表/列/操作符不合法）。

---

## 4. 插槽与钩子

### 4.1 显示插槽（A 档：只改数据）

| 插槽 id | 插件返回 | 主包负责 |
|---|---|---|
| `slot.headerDate` | `{text: "十月初十 周四"}` | 字号、颜色、位置 |
| `slot.pointsBadge` | `{value: 120, route: "/points"}` | 徽章外观、可见性 |
| `slot.calendarMarks` | `{"2026-10-22": "dot", …}` | 格子与标记的画法 |
| `slot.taskCardExtra` | `{taskId: 12, text: "已专注 3 次"}` | 排版、截断 |

- 插件**不能**返回 HTML/CSS/颜色/字号，只能返回文本与枚举
- 一个插槽有多个插件声明时：按插件安装顺序取第一个，其余忽略并记日志（不做优先级仲裁，避免冲突）

### 4.2 事件钩子（没人订阅也不能出错）

| 钩子 | payload | 发点（**已接通**） |
|---|---|---|
| `task.completed` | `{taskId, title, dueDate, priority, estimatedMinutes, tags}` | `TaskStore.toggle`（勾选变完成）、`PluginBridge.task.setDone`（且只在**状态真的变了**时发） |
| `task.recycled` | 同上 | `TaskStore.remove` / `PluginBridge.task.delete`，**只在真的进了回收站时** |
| `task.restored` | `{title, dueDate}` | 回收站页的「恢复」 |
| `pomodoro.sessionFinished` | `{mode, durationSeconds, actualSeconds, taskId?}` | 尚未接通（番茄钟插件还没做） |

- 钩子是**通知**，不是拦截：插件拿不到"取消这次操作"的权力
- 钩子超时（>500ms）或报错 → 记日志、继续主流程，**绝不让插件阻塞任务完成**
- 这是"平台不会被插件拖垮"的底线
- **payload 只给订阅方能算结果的字段**：估时、优先级、标签都在，描述不给
  （那是用户写给自己的，插件没理由看）
- **重复操作不重复发**：插件页面刷新时可能重放 `setDone(true)`，
  如果每次都发，货币插件就会重复发奖 —— 所以只在状态真的变化时发。

**订阅方式**：在 `plugin.json` 里声明，页面里用 `host.on` 接。

```json
"hooks": ["task.completed"]
```

```js
window.host.on('task.completed', function (payload) {
  // payload: {taskId, title, dueDate, priority, estimatedMinutes, tags}
});
```

- **没声明就收不到**（宿主根本不推），不是"能收但收不到"
- 同一事件可挂多个处理函数；某个处理函数抛异常不影响其他
- 页面加载完成前的**事件会排队**（上限 20 条，满了丢最老的），加载完成后按顺序补发；
  页面重载期间回到排队状态，不会往旧 JS 上下文里发
- 推送失败一律吞掉：插件收不到事件不该让主流程失败

实现在 `lib/core/plugin/plugin_hook_channel.dart`，宿主侧 `PluginView` 负责
注册/注销（注销按实例而不是按 pluginId —— 同一插件可能同时开着两个页面）。

**补发：插件没挂载时事件不许丢。**

做"常驻隐藏 WebView"是不划算的：每个几十 MB、要处理前后台、被系统杀掉还补不回来。
所以改成落库 + 补发：

| 方法 | 权限 | 说明 |
|---|---|---|
| `event.pending({since?, limit?})` | `task:read` | 返回 `[{id, event, payload}]`，按发生顺序，只含 manifest 声明过的钩子 |
| `event.ack({ids})` | `task:read` | 处理完才确认；**没 ack 会再次投递**，所以插件必须按 `id` 幂等 |

- 事件写在 `plugin_events` 表（宿主的基础设施表，不是插件的 `plg_` 私有表）
- `event.pending` 也要 `task:read`：payload 里带着任务标题/日期/估时，
  等于一份任务数据 —— 只声明 hooks 而不给读权限，拿不到内容
- 表里只放"还没确认"的事件，ack 即删；另有 200 条上限兜底（超了删最老的）

```js
window.host.call('event.pending').then(function (list) {
  list.forEach(handle);                       // 按 id 去重，别重复发奖
  return window.host.call('event.ack', { ids: list.map(e => e.id) });
});
```

---

### 4.3 服务级替换（风险最高，白名单极少）

插件还可以替换主包的某个**服务实现**，而不只是喂数据。第一个（也可能是长期唯一的）案例：
**货币的产出规则**。

```json
"services": [
  { "id": "currency.earnPolicy", "impl": "task-reward" }
]
```

- **白名单制**，首版只开放 `currency.earnPolicy` 一项
- 同一时刻**只能有一个实现生效**（与显示插槽"取第一个"的规则不同，这里必须互斥）
- 必须有**回退**：插件卸载或禁用 → 立刻回落到主包默认实现，不留中间态
- **只允许换算法，不允许换表结构**：插件不得新增/修改 `user_points`、`points_records` 的列

**为什么它比显示插槽危险**：显示插槽画错了只是难看，服务替换错了会**改数据语义**。
所以它的准入最严，且每次开放都要单独过一遍"换个实现之后旧数据还读得懂吗"。

---

## 5. 入口注册

插件在 manifest 里声明它要出现在哪：

```json
"entries": [
  { "where": "sidebar", "label": "番茄钟", "icon": "timer", "order": 20 },
  { "where": "profile", "label": "积分明细", "order": 10 }
]
```

- `where` 只允许 `sidebar` / `profile` / `settings` 三个白名单值
- **不允许插件自己决定图标图片**（首版用内置图标名，避免风格割裂）
- 卸载后入口自动消失，不留空位

---

## 6. 分发

沿用现有更新体系，不新建服务器：

- **索引**：`plugins/index.json`（托管在现有 GitHub 仓库，走 jsDelivr 多源 + Contents API 兜底）
- **包**：GitHub Releases 或仓库内 `plugins/packages/<id>-<version>.zip`
- **体积**：单包 ≤ 20MB（jsDelivr 硬限；超过走 Releases）
- **校验**：索引里带 `sha256` 与 `sizeBytes`，装前必验，不符即删包重试下一源
- **离线**：索引拉取失败 → 用本地缓存的索引；缓存也没有 → 只显示已装插件

索引结构（**与代码一致**，`assets/plugins/index.json`）：

```json
{
  "schemaVersion": 1,
  "plugins": [
    {
      "id": "demo_help",
      "name": "使用说明",
      "version": "1.1.1",
      "contract": 1,
      "description": "一句话描述",
      "icon": "help",
      "permissions": ["task:read", "task:write"],
      "package": {
        "path": "assets/plugins/demo_help_v1.1.1.zip",
        "sha256": "…64 位小写十六进制…",
        "sizeBytes": 2575
      }
    }
  ]
}
```

**`permissions` 是索引里唯一的"冗余"字段**：正常情况下索引不含 manifest 内容
（避免"索引说 1.0、包里是 2.0"），但权限必须在**下载之前**就知道 ——
否则没法在安装前告诉用户"这个插件能改你的任务"。
它由打包脚本 `tool/make_demo_plugin.py` 从 `plugin.json` 复制，
不是手写的；真正生效的授权仍以包内 manifest 为准。

**安装前必须告知**：点「安装」先弹一个确认框，按权限逐条列出人话
（`读取你的任务…` / `新建和修改你的任务` / `删除你的任务`），
没有权限也要弹（明确说"不需要任何数据权限"）。文案映射在
`lib/core/plugin/permission_copy.dart`，新增权限必须同步加一句，
否则界面会露出 `未知权限：xxx`。

**信任根**：索引 JSON 本身。谁能改仓库谁就能投毒 → 首版靠"仓库只有你一个写入者"，
如果将来要更严，加一层 `index.json.sig`（离线私钥签名，App 内置公钥验签）。

---

## 7. 安装 / 卸载 / 数据

| 场景 | 行为 |
|---|---|
| 安装 | **先弹窗列出权限** → 下载 → 验 sha256 → 解压到临时目录 → 校验 manifest → **冷启动后生效** |
| 更新 | 同安装；旧版本目录改名 `.bak-<stamp>` 保留，成功后删 |
| 卸载 | 移除代码与入口；**弹窗问"是否保留数据"**，默认保留 |
| 卸载且删数据 | `DROP TABLE plg_<id>_*` + 清 `plg.<id>.*` 设置键 |
| 安装失败 | 回滚到上一可用版本，不留半旧半新 |

**「冷启动生效」是刻意的**：运行期不加载/不卸载代码，避免状态不一致。
代价只是"装完要重开 App"，换来的是可控性。

---

## 8. 这份契约里还没定的

- [ ] 权限粒度是否够（现在的 6 组够不够用）
- [ ] 插件间是否需要"共享数据"（目前设计成完全隔离，只经主包）
- [ ] 索引签名要不要做（首版可以不做，但要把字段位置留出来）
- [ ] 插件页面与本机主题的同步方式（bridge 传色值 vs 注入 CSS 变量）
- [ ] 插件内的返回手势、状态栏、输入法适配由谁负责（建议：宿主统一处理）
