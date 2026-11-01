# AI 辅助开发入口

> 最后更新：2026-11-01

这份文档是**所有平台 AI agent 的共同起点**。你所在平台自己的记忆/规则文件不共享，
也不可信；**仓库文档才是唯一共享记忆**。

## 1. 开工前必读（按顺序，读完再动手）

1. `docs/INDEX.md` —— 文档地图 + 已证伪断言清单
2. `docs/decisions.md` —— 既有取舍“为什么这么定”
3. `docs/conventions/README.md` —— 规范唯一入口与优先级
4. `docs/conventions/architecture.md` —— 代码放哪、依赖方向、扩展位
5. `docs/conventions/collaboration.md` —— 分工、文件所有权、交接、证据规则
6. `docs/conventions/coding.md` —— 代码/测试/数据/UI 的具体规则
7. `docs/conventions/delivery.md` —— 交付、验收、提交/推送
8. 任务相关的 skill（见 §3）

**不要**只读 README 或只读聊天上下文就开工。上下文被压缩/换窗口后，从第 1 条重来。

## 2. 先建任务文件

非平凡任务先在 `docs/ai/work/<YYYY-MM-DD>-<英文短名>.md` 建 claim 文件，
模板 `docs/ai/templates/task-claim.md`。文件至少写清：范围、涉及文件、验收口径、
当前状态、交接区。没有任务文件就不要开始改多个文件。

真人小改动（文案/单文件 UI/注释）可跳过任务文件，但仍要走交付纪律。

## 3. 任务路由：先选 skill，再动手

| 任务类型 | Skill | 关键产出 |
|---|---|---|
| 主包新功能/字段/页面 | `docs/ai/skills/feature-dev/SKILL.md` | 实现 + 测试 + 验收清单 |
| 插件开发/发布 | `docs/ai/skills/plugin-dev/SKILL.md` | 插件包 + 索引 + 市场可见 |
| 修 bug/回归 | `docs/ai/skills/bugfix/SKILL.md` | 反向测试 + 机制/保险 |
| 发版/清单/CDN | `docs/ai/skills/release/SKILL.md` | 包 + Release + update.json |
| 验收/交付说明 | `docs/ai/skills/acceptance/SKILL.md` | 可量化验收清单 |
| 文档整理/归档 | `docs/ai/skills/docs-maintenance/SKILL.md` | INDEX/归档/唯一源 |

Skill 是**流程清单**，不是规则来源。规则冲突时以 `docs/conventions/` 为准。

## 4. 规则卡（按需加载，不要全读）

| 规则卡 | 什么时候读 |
|---|---|
| `docs/ai/rules/rule-architecture.md` | 改动跨 core/app、扩展位、单一判据 |
| `docs/ai/rules/rule-data.md` | 改表/列/迁移/插件表/删除语义 |
| `docs/ai/rules/rule-plugin.md` | 改 manifest/权限/bridge/事件/分发 |
| `docs/ai/rules/rule-delivery.md` | 准备提交/推送/发版/验收 |
| `docs/ai/rules/rule-docs.md` | 新增/修改/归档文档 |

规则卡只做“定位 + 检查项”，条文在 `docs/conventions/` 与 `docs/decisions.md`。

## 5. 标准工作流（任何任务都适用）

```
① 读（§1 + 任务相关源码）
② claim（写任务文件，声明范围与文件）
③ 定案（方案、代价、放弃项；接口/数据变更先写 decisions）
④ 实现（小步；先跑通再美化）
⑤ 自检（analyze + 全量测试 + 迁移/反向测试）
⑥ 验收（机器判定 vs 人判定；写 docs/acceptance/）
⑦ 签收（用户勾；不过的编号回到 ④）
⑧ 提交（验证过的小步；不推送）
⑨ 推送（攒够一件事 + 用户签收后合并成一条）
```

没有 ⑥，不要说“做完了”。没有 ⑦，不要推送。

## 6. 多 agent 协作（不共享上下文）

- **文件所有权**：见 `docs/conventions/collaboration.md` §3；不跨目录直接改。
- **接口变更**：先写 `docs/decisions.md`，再改代码，再通知相关 owner。
- **交接**：在任务文件“交接区”写清已完成/下一步/坑/未验证；不要只留在聊天里。
- **证据**：任何“发现/已修复/已验证”必须能指到文件:行号或命令输出；
  “应该验证”只能写成待办。
- **禁止**：假设其他 agent 记得你上一轮；把平台本地记忆当项目规则；
  为了让任务看起来完成而降低验收标准。

## 7. 上下文压缩/换窗口后的恢复

按这个顺序重读，不要凭印象：

1. `docs/ai/README.md`（本文）
2. `docs/INDEX.md`
3. `docs/decisions.md`
4. 当前任务文件 `docs/ai/work/<任务>.md`
5. 任务相关 skill + 规则卡

如果你不确定“上一轮做到哪”，以任务文件和 `git status` 为准，不要以聊天记忆为准。

## 8. 平台适配（只做指针，不复制规则）

- **Trae / Claude Code / Cursor / 其他**：把根目录 `AGENTS.md` 或本文路径配成项目入口；
  规则正文只读 `docs/conventions/`。
- 不要在各平台再建一份 `rule-*.md` / `CLAUDE.md` 全文；需要就写 5 行指针：
  “先读 docs/ai/README.md，规则唯一源 docs/conventions/”。
- 平台自动生成的“项目记忆”可能残留旧规则；发现冲突以仓库文档为准，并提醒用户核查。

## 9. 不要做的事

- 不要虚构文件、命令、bug、脚本；发指令前先确认它存在。
- 不要用“测试全过”替代真机验证；平台层问题必须真机/模拟器。
- 不要先改 `update.json` 后传包；不要在未签收时推送。
- 不要新增重复规则副本；不要在没有决策记录的情况下改契约/数据/发布链路。
- 不要为了让页面“看起来完整”放一个点不动的占位入口。
