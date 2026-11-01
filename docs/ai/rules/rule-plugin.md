# 规则卡 · 插件契约

> 最后更新：2026-11-01
> 适用：改 manifest、权限、bridge、插槽/钩子、插件表、安装/升级/分发。

## 必须

- `id` 只允许 `[a-z][a-z0-9_]{1,31}`；`entry` 必须是包内相对 `.html` 路径。
- 权限默认空集；读/写/删分开；新增权限同步 `PluginManifest.knownPermissions`、
  `PluginBridge`、`PermissionCopy`、契约文档。
- 插件只走 bridge；自己的数据只能落 `plg_<id>_*` 与 `plg.<id>.*` KV。
- `db.update`/`db.delete` 必须带 `where`；永不执行插件传来的 SQL。
- 事件：manifest 声明 `hooks` 才收；payload 只给算结果需要的字段（不含描述）；
  没挂载用 `event.pending`/`event.ack`，按 id 幂等。
- 版本从 `system.info` 取；HTML 不许写死版本号。
- 插件升级后必须换 WebView（`clearCache` + `file://` 不信任缓存 + `version` key）。
- 分包：默认只走仓库；随包只允许“断网必须可用且没它 App 不能用”；两边不能都有。
- 打包幂等；索引 sha/size 由脚本算；下载后验 sha256；超 20MB 下载前拒绝。

## 禁止

- 插件碰主包表、执行任意 SQL、声明自己不认识的权限/插槽/钩子还要求装得上。
- 插件自己决定“彻底删除”；删除必须跟随用户回收站设置。
- 插件模式下由主包画 `+`；需要新建入口由插件自己提供。
- 让插件阻塞任务完成/事件派发；钩子当拦截器。
- 把 `contract` 回显给用户（市场页除外）；把版本号写死在 HTML。
- 先改索引再传包；同版本重打包改字节。

## 判据

| 问题 | 判据 |
|---|---|
| 装不装得上 | `PluginContract.accepts(contract)` |
| 能不能当首页 | 所有插件都能；`home` 只决定默认开不开 + 名字 |
| 能不能写任务 | `task:write`；删还要 `task:delete` |
| 插件能不能读主包统计 | 不能直接读；需要宿主新增只读契约 |
| 卸载留不留数据 | 默认留；删数据要用户主动勾选并明确提示 |

## 参考

`docs/plugin-contract.md`、`docs/decisions.md` 插件相关条目
