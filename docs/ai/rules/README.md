# 规则卡索引

> 最后更新：2026-11-01

规则卡是**定位 + 检查项**，不是规则来源。条文在 `docs/conventions/` 与
`docs/decisions.md`；冲突时以它们为准，并修正本卡。

## 用法

- 不要一次全读；按任务选 1–2 张。
- 每张卡开头写“适用/必须/禁止/判据”，正文只列最容易踩的点。
- 发现卡里说法过期：改卡，不要把旧说法留在仓库里。

## 索引

| 卡 | 什么时候读 | 权威文档 |
|---|---|---|
| `rule-architecture.md` | 跨 core/app、扩展位、单一判据 | `docs/conventions/architecture.md` |
| `rule-data.md` | 改表/列/迁移/插件表/删除语义 | `docs/conventions/architecture.md` §3 + `docs/decisions.md` |
| `rule-plugin.md` | manifest/权限/bridge/事件/分发 | `docs/plugin-contract.md` |
| `rule-delivery.md` | 提交/推送/发版/验收 | `docs/conventions/delivery.md` |
| `rule-docs.md` | 新增/修改/归档文档 | `docs/INDEX.md` + `docs/conventions/README.md` |

## 不做什么

- 不在卡里复制完整条文（会变成第二份真相）。
- 不新增“通用原则”卡；原则进 `docs/conventions/`。
- 不把平台本地规则写进卡；各平台只做指针。
