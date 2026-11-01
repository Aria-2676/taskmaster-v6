# Agent 入口（指针，不放规则）

> 最后更新：2026-11-01

任何平台的 AI agent 进入本仓库，先按这个顺序读，再动手：

1. `docs/ai/README.md` —— 开工顺序、任务路由、skills、规则卡
2. `docs/INDEX.md` —— 文档地图 + 已证伪断言
3. `docs/decisions.md` —— 既有取舍“为什么这么定”
4. `docs/conventions/README.md` —— 规则唯一源与优先级
5. 当前任务文件 `docs/ai/work/<日期>-<主题>.md`（没有就先建）

**每轮开工**：让协调者填 `docs/ai/templates/session-start.md` 的开工卡（任务 / 授权 /
红线 / 验收口味）；环境类状态（设备在线、工作区干净、版本、测试总数）自己查，不要问人。

**硬约束**

- 仓库文档是唯一共享记忆；不要假设其他平台/agent 记得你上一轮。
- 规则只读 `docs/conventions/`；`docs/ai/rules/` 只是检查清单。不要把平台本地规则当项目规则。
- 非平凡任务先建 `docs/ai/work/` 任务文件；不跨文件所有权直接改。
- 接口/数据/契约/发布链路变更，先写 `docs/decisions.md`。
- 任何“发现/已修复/已验证”必须能指到文件:行号或命令输出。
- **未验收不推送**；只在用户明确要求时提交/推送。
- 不要虚构文件、命令、bug、脚本；发指令前先确认它存在。

本文件只做指针，不复制条文。规则冲突时以 `docs/conventions/` 与 `docs/decisions.md` 为准。
