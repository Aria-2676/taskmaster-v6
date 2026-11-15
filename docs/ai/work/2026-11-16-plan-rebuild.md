# 任务 · 6.6.0 计划重建（计划 / 阶段 / 里程碑 + 排入任务）

> 日期：2026-11-16 ｜ 状态：in_progress
> 协调者：用户 ｜ 实现者：WorkBuddy ｜ 核查者：用户

## 范围

- 要做：
  1. 计划有**自己的数据**：`plg_plan_plans`（计划）+ `plg_plan_stages`（阶段）
     + `plg_plan_milestones`（里程碑）+ `plg_plan_tasks`（关联任务）
     —— `decisions.md` 699 放宽的前提就是这些是新实体
  2. 计划列表：名字 / 目标 / 日期范围 / 进度
  3. 计划详情：阶段（可勾选）、里程碑（日期 + 勾选）、关联任务（含完成率）
  4. 排入任务：从主包未完成任务里挑，加进计划
  5. 保留改期能力：计划里的任务点一下能改日期（原周视图的核心价值）
- 明确不做：
  - 周/月甘特视图（排期可视化留到以后）
  - 计划间的依赖关系

## 涉及文件/目录

- `plugins/src/plan_mode/plugin.json`（storage + 2.0.0）
- `plugins/src/plan_mode/index.html`（重写）
- `plugins/src/plan_mode/query.html`（改：plan.list 返回真实计划）
- `plugins/packages/*.zip`、`assets/plugins/index.json`

## 依赖

- 前置：6.5 验证过的 storage 用法；`task.list` / `task.update` 已有
- 需要裁决：无

## 验收

- 人判定（模拟器）：
  1. 新建计划（名字 + 起止日期）→ 出现在列表，进度 0%
  2. 加 2 个阶段、1 个里程碑 → 勾掉 1 个阶段 → 进度变化
  3. 排入 2 个主包任务 → 完成率按任务算
  4. 重启 App → 数据都在

## 风险

- 数据：新表，旧版 1.3.1 没存过计划数据，无迁移
- 真机：键盘遮挡（清单里出现过，这次注意）

## 交接区

### 已完成
- 读过 plan_mode 1.3.1（只改任务日期，不建表）

### 下一步
- storage → 页面 → 打包 → 模拟器验

### 已知坑
- prompt 会弹原生框（清单已换成页面内弹层，这里照抄）
- 模拟器 preview 包 versionCode 大，装新包要先 uninstall
