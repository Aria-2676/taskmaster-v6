---
name: feature-development
description: 在 taskmaster-v6 主包里开发新功能、字段、页面或能力时使用。强制先定案再动手，产出代码、测试和可量化验收清单。
---

# 主包功能开发

> 最后更新：2026-11-01

## 什么时候用

- 新增任务字段、编辑页/设置页/回收站等主包页面能力
- 新增主包服务（计时、通知、搜索、循环生成等）
- 调整已有功能的行为或数据语义

**不适用于**：插件包开发（用 `plugin-dev`）、纯 bug 修复（用 `bugfix`）、发版（用 `release`）。

## 输入

- 用户需求/路线图中的一条能力
- 相关源码、`docs/decisions.md`、`docs/conventions/architecture.md`

## 步骤

1. **读上下文**：`docs/INDEX.md` → `docs/decisions.md` → 架构/编码规范 → 相关源码。
2. **claim 任务**：在 `docs/ai/work/<日期>-<英文短名>.md` 写范围、涉及文件、
   验收口径、明确不做什么。
3. **定案**：先写清方案、代价、放弃项。涉及以下任一，先写 `docs/decisions.md`：
   - 数据库表/列/迁移语义
   - 插件契约、bridge、插槽/钩子、`AppDestination`、`SettingsKeys`、备份格式
   - 新增依赖
4. **定验收**：先写“怎么算完成”。能自动化的写成测试，手感的标“需真机”。
5. **实现顺序**：core 能力 → app 状态/仓储 → UI → 测试。
   - 数据改动：先改 schema/迁移，再改仓储，再改 UI。
   - 字段：加到 `FieldCatalog` + 一列 + 迁移测试；编辑页/字段管理由表驱动。
6. **自检**：`flutter analyze lib` + 全量 `flutter test`；迁移造老库测试；
   修 bug 加反向测试。
7. **写验收清单**：`docs/acceptance/<日期>-<主题>.md`，按模板分层。
8. **更新文档**：`docs/INDEX.md` 唯一源；取舍进 `docs/decisions.md`；
   路线图进度更新 `docs/ROADMAP.md`。
9. **本地提交**：一个可独立回退的小步；提交信息写“为什么”。**不推送**，等签收。

## 输出

- 代码 + 测试
- 验收清单（机器判定 / 人判定 / 已知未做）
- 必要的决策记录与文档更新

## 硬规则

- **字段永远在主包**，插件不贡献字段。
- **不要 over-engineer**：只做需求需要的抽象；没有调用点的工具类不要造。
- **一个新语义只允许一个判据**；能复用 `AppDestination`/`FieldCatalog`/`SettingsKeys` 就复用。
- 数据迁移必须配“造真老库再打开”的测试；删除 API 不留默认值。
- 没有真机跑过的手感/平台层功能，交付说明必须写“未在真机验证”。
- 没有验收清单，不要说“做完了”。

## 参考

- `docs/conventions/architecture.md`
- `docs/conventions/coding.md`
- `docs/conventions/delivery.md`
- `docs/ai/rules/rule-architecture.md`、`rule-data.md`、`rule-delivery.md`
