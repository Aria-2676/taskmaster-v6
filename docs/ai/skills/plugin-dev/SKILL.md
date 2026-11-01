---
name: plugin-development
description: 开发、打包、发布 taskmaster-v6 插件时使用。覆盖 manifest、权限、bridge、私有表、事件、首页模式、打包与分发。
---

# 插件开发与发布

> 最后更新：2026-11-01

## 什么时候用

- 新增页面型插件、模式插件（当首页）、货币插件
- 给插件加 bridge 能力、事件订阅、私有表
- 打包/发布插件、更新索引、排查插件装不上

**不适用于**：主包内部功能（用 `feature-dev`）、只改 App 版本（用 `release`）。

## 先读

- `docs/plugin-contract.md`（包格式、权限、bridge、插槽/钩子、分发）
- `docs/decisions.md` 中插件相关条目（升级/卸载/停用/首页/首次分发）
- `lib/core/plugin/plugin_manifest.dart`、`lib/app/data/plugin_bridge.dart`（代码为准）

## 插件类型（先选对）

| 类型 | 形态 | 例子 |
|---|---|---|
| 页面型 | 整页 WebView | 使用说明、商城 |
| 模式型 | 整页 + `home` 声明，可当首页 | 计划模式、清单模式 |
| 货币型 | 页面 + `currency:read/write`，主包只存镜像 | 能量 |
| 插槽型 | 只通过 bridge 供数据，主包渲染 | 日历标记、卡片附加行 |

**插件不能提供 Dart UI**；区域级插槽只给数据，不给样式。

## 步骤

1. **claim 任务**，写清插件 id、类型、要用的权限/桥方法/表。
2. **写 `plugin.json`**：
   - `id` 只允许 `[a-z][a-z0-9_]{1,31}`（会成为目录名与表前缀）
   - `version` 必须 `x.y.z`；`contract` 与宿主 `PluginContract.current` 兼容
   - `entry` 必须是包内相对 `.html` 路径，不能 `..`/绝对路径/反斜杠
   - `permissions` 最小化：读/写/删分开，不声明就拿不到
   - `home` 可选：`{label, hint, order}` 或 `true`；**不是准入**
   - `storage` 可选：声明表/列/索引；表名/列名小写，`id` 由宿主加
3. **实现页面**：
   - 等 `window.host` 就绪再调；版本从 `system.info` 取，**不许写死**
   - 写操作后依赖宿主的 `onChanged` 刷新，不要自己维护第二份任务数据
   - 事件按 id 幂等；没挂载时用 `event.pending` + `event.ack`
   - 不要把主包数据复制到插件自己的表（除非它就是“这个插件的历史”）
4. **加 bridge/权限（如果需要）**：先写 `docs/decisions.md`；同步
   `PluginManifest.knownPermissions`、`PluginBridge`、`PermissionCopy`、契约文档；
   判断契约版本是否 +1。
5. **打包**：`python tool/make_demo_plugin.py`；索引 sha/size 由脚本算，不手写。
6. **决定分发**：默认只走仓库（`plugins/packages/`）；只有“断网必须可用且没它 App 不能用”
   才随包。随包/仓库只能二选一（`asset_index_test` 会红）。
7. **自检**：
   - `flutter analyze lib` + 全量 `flutter test`
   - 索引与包内 manifest 一致（版本/权限/home/storage）
   - 打包幂等：同内容跑两次字节不变
   - 市场安装/升级/停用/卸载；升级后页面刷新（清缓存 + 换 key）
8. **发布**：`tool/publish_plugin.ps1`（打包 → 版本守卫 → 提交 → 推送 → 刷缓存）。
   **不需要发 App 版本**。
9. **验收**：写 `docs/acceptance/`，至少覆盖：装/升级/卸载/停用/断网/首页切换。

## 硬规则

- 插件永不直连数据库；只用 bridge；自己的数据只能落 `plg_<id>_*` 与 `plg.<id>.*` KV。
- `db.update`/`db.delete` 必须带 `where`；永不执行插件传来的 SQL；表/列必须声明过。
- 权限未声明 → `permission_denied`，不静默；新增权限必须补 `PermissionCopy`。
- 事件是通知不是拦截；插件收不到事件不能影响主流程；payload 不含描述。
- 插件升级后必须换掉旧 WebView（`clearCache` + `file://` 不信任缓存 + version key）。
- 主页面的 `+` 不由主包给插件画；需要新建入口由插件自己提供。
- 插件包名带版本号；同版本重打包不得改字节。
- 插件 id/路径校验严格；下载后必须验 sha256；体积超 20MB 下载前拒绝。

## 输出

- `plugins/src/<id>/` 源码
- `plugins/packages/<id>_v<ver>.zip` + 更新后的 `assets/plugins/index.json`
- 验收清单与必要的契约/决策文档更新

## 参考

- `docs/plugin-contract.md`
- `docs/conventions/architecture.md` §4
- `docs/ai/rules/rule-plugin.md`
- `tool/README.md`
