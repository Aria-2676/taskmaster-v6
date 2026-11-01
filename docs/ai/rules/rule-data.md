# 规则卡 · 数据与迁移

> 最后更新：2026-11-01
> 适用：改 `v6_schema.dart`、`v6_database.dart`、`v6_plugin_tables.dart`、仓储层、删除/恢复语义。

## 必须

- 列名一律用常量（`V6Table` / `TaskCol` / `SettingsKeys` 等）；SQL 里不出现裸字符串。
- 迁移写法：`newVersion > version` 抛；`oldVersion < N` 补一步，不用 `if (old == N)`。
- **每条迁移配“造真老库再打开”的测试**（`v6_migration_test.dart` 同款）。
- 插件表只能 `plg_<id>_<suffix>`；`plg_migrations` 独立版本；按前缀守卫删除。
- 删除 API 不留默认值；`toRecycle` 必须显式传。
- 跨表操作走事务；先删关联再删主行/子查询顺序要写清。
- 外部数据 fail-soft：顶层结构错 → 抛；单字段错 → 丢字段。
- 插件删除跟随用户回收站设置；插件不能自己决定彻底删。

## 禁止

- 引入 drift/build_runner（除非有决策记录并评估 182 处调用点）。
- 用 `recycled_tasks.id` 当 `task_id` 清关联（会误删活任务标签）。
- 让插件指向主包表或执行任意 SQL。
- 删除时静默留下 `task_tags`/插件表孤儿。
- 时间格式混用（任务日期 `yyyy-MM-dd`；时间戳明确本地/UTC）。

## 判据

| 场景 | 正确做法 |
|---|---|
| 新增字段 | 可空列 + `FieldCatalog` 一条 + 迁移测试 |
| 恢复任务 | 写回原 id 或明确说明新 id 的影响；标签快照重建只选仍存在的标签 |
| 卸载插件留数据 | 不 DROP 表；删数据才 DROP + 清 `plg.<id>.*`/货币镜像/熔断计数 |
| 插件聚合 | 只查自己声明的表；统计主包历史需要宿主只读契约 |

## 参考

`docs/conventions/architecture.md` §3、`docs/decisions.md` 数据相关条目
