# 协作与工程规范（唯一入口）

> 最后更新：2026-11-01

本目录是**规则的唯一源**。人和 AI 都从这里读，不再把规则抄到 `.trae/rules/`、
`CLAUDE.md`、`.workbuddy/skills/` 或聊天记录里。旧副本只作历史，不再维护。

## 1. 先读什么

任何改动之前，按这个顺序读（读完再动手，不要凭印象）：

1. `docs/INDEX.md` —— 文档地图 + **已证伪断言清单**
2. `docs/decisions.md` —— 既有取舍“为什么这么定”
3. `docs/conventions/architecture.md` —— 代码放哪、依赖方向、扩展位边界
4. `docs/conventions/collaboration.md` —— 多人/多 agent 怎么分工、怎么交接
5. `docs/conventions/coding.md` —— 写代码、写测试、改配置的具体规则
6. `docs/conventions/delivery.md` —— 交付流程、验收、提交/推送
7. 任务相关的 `docs/ai/skills/*/SKILL.md`

AI agent 的入口是 `docs/ai/README.md`；根目录 `AGENTS.md` 只做指针，不放条文。

## 2. 规则冲突时听谁的

优先级从高到低：

1. **代码当前行为** —— 回答“现在是什么样”。
2. **`docs/decisions.md`** —— 回答“为什么这么定、否掉了什么”。
3. **本目录** —— 回答“以后必须怎么做”。
4. **`docs/ROADMAP.md`** —— 回答“接下来做什么、什么时候算完成”。
5. **`docs/ai/skills/` 与 `docs/ai/rules/`** —— 只是导航和检查清单，不产生新规则。

发现冲突：先停手，把冲突写进任务文件/决策记录，由协调者定；不要自行选一个继续做。
**代码与文档冲突时，默认代码是事实；但如果是“规则要求而代码没做到”，改代码，不要改规则迁就代码。**

## 3. 唯一源分工

| 内容 | 唯一源 | 别再写到 |
|---|---|---|
| 文档地图、已证伪断言 | `docs/INDEX.md` | README、decisions |
| 取舍与原因 | `docs/decisions.md` | 规范文档、验收清单 |
| 规则（架构/协作/编码/交付） | `docs/conventions/` | `.trae/`、`CLAUDE.md`、`.workbuddy/`、聊天记录 |
| 后续计划与出口条件 | `docs/ROADMAP.md` | README、日记 |
| 验收清单与模板 | `docs/conventions/acceptance-template.md` + `docs/acceptance/` | 回复正文以外的第二份 |
| AI 开工顺序、任务路由 | `docs/ai/README.md` | 各平台本地记忆 |
| 正在进行的任务与交接 | `docs/ai/work/<日期>-<主题>.md` | 聊天上下文、平台记忆 |

**同一句话只允许有一个权威位置。** 需要引用时写“见某文件”，不要把条文复制过去。
这是 V5 时代用三份规范副本付过代价的教训。

## 4. 文件地图

| 文件 | 负责什么 |
|---|---|
| `architecture.md` | 目录边界、依赖方向、数据/插件/扩展位、单一判据、错误处理 |
| `collaboration.md` | 角色、任务 claim、文件所有权、接口变更、交接、证据规则 |
| `coding.md` | Dart/Flutter、测试、SQL、UI、插件、脚本与配置 |
| `delivery.md` | 定案→实现→自检→验收→签收→提交/推送；发版顺序 |
| `acceptance-template.md` | 验收清单骨架、好坏预期示例、机器/人分层 |

历史记录（已实现的设计、已签收的验收）去 `docs/archive/`，只读不改。

## 5. 改规则的规则

- 改规则前先问：**这是新规则，还是既有规则换了个说法？** 后者不要新增文件。
- 新增一篇规则必须同时改 `docs/INDEX.md` 的文件分工表；否则等于没写。
- 新写或修改的文档在标题下加 `> 最后更新：YYYY-MM-DD`；**不回填旧文档**。
- 常读文档有行数上限：单篇超过约 200 行就拆开或把细节移入 `docs/archive/`。
- 被证伪的断言不留“参考”，在 `docs/INDEX.md` 留一行“曾这么写过、为什么错”。
- 规则改动如果影响插件/外部契约，必须同时改 `docs/plugin-contract.md` 并考虑契约版本。

## 6. 给不同平台的 AI agent

- 每个平台都有自己的记忆/规则文件，**它们不共享，也不可信**。仓库文档才是共享记忆。
- 接到任务先读 `AGENTS.md` → `docs/ai/README.md`，按 §1 顺序加载；不要假设“上一个 agent 已经知道”。
- 上下文被压缩/换窗口后，先重读 `docs/ai/README.md`、`docs/INDEX.md`、
  `docs/decisions.md` 和当前任务文件，再继续。
- 不要把你所在平台的规则文件内容当成项目规则；以本目录为准。

## 7. 给真人协作者

真人做小改动时也要遵守同样的红线：

- **未验收不推送**；推送前合并提交。
- 改数据/契约/发布链路，必须走任务文件 + 决策记录，不能“顺手改一下”。
- 只改文案/单文件 UI 的小改动可以不走完整任务文件，但仍要：
  `flutter analyze lib` + 相关测试通过 + 提交信息写“为什么”。
- 不确定时先问，不要用“我觉得应该”替代项目事实。
