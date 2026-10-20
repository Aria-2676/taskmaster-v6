# Spike 阶段记录（历史文档）

> **本文是 Spike 阶段的历史记录，不是当前工程的操作手册。**
>
> 本仓库（`taskmaster-v6`）就是从那次 Spike 演进来的。下面原文里的
> 「未编译 / 没有 node_modules / 待验证」等措辞**是当时的状态，现已不成立**：
> Spike 六项验收（金样本、番茄钟、桌面小组件、OTA 全链路、通知、启动健康）
> 已全部真机通过，工程也已从 `rn/` 子目录提到仓库根，并完成了 v6 包名改名。
>
> **路径已随工程迁移更新**（原文写的是 `rn/` 子目录与 `docs/migration/`，
> 现分别为仓库根与 `docs/`）。除路径外的内容保持原样，未作改写。

---

## 原文（路径与包名已更新）

> 这里只放 **M0（工程 + 数据）** 需要的东西。
> 契约文档：`docs/schema-v3.md`、`docs/business-rules.md`。
> 金样本：`fixtures/golden-v3.db`（由 `tool/make_golden_sample.py` 生成，已 gitignore）。

## 目录

```
（当时是 rn/，现为仓库根）
├─ src/
│  ├─ db/schema.ts          # v3 建表 DDL（与契约文档逐字对应）
│  ├─ db/index.ts           # 打开旧库 + 5 个验收查询
│  ├─ spike/verifyGolden.ts # 金样本比对，输出 PASS/FAIL
│  └─ ota/manifest.ts       # 清单模型
└─ README.md
```

## 为什么包名要带 `.spike`（当时）

Spike 必须能和线上 Flutter 版**同时装在一台机器上**，所以要换包名：

- 线上（Flutter v5）：`com.noteapp.taskmaster`
- Spike（当时）：`com.noteapp.taskmaster.spike`
- **现在（v6）**：`com.noteapp.taskmaster.v6`

代价是 Android 沙箱隔离——**Spike 读不到线上应用的私有目录**。所以数据来源是金样本（`adb push`），不是直读。这不是权限问题，是系统隔离。

## 初始化工程（当时需要联网，一次）

```bash
# 1) 用官方模板初始化（会装依赖，耗时较长）
npx @react-native-community/cli@latest init TaskMasterSpike --directory rn-tmp

# 2) 把骨架的 src 合进去（保留本目录的 src）
cp -r rn-tmp/. rn/
#    Windows: robocopy rn-tmp rn /E

# 3) 依赖（版本以模板生成为准，不要手抄）
npm i @op-engineering/op-sqlite
```

初始化时把 Android 包名设为 `com.noteapp.taskmaster.spike`（或在 `android/app/build.gradle` 的 `applicationId` 改）。

## 跑金样本验收（Spike 第 1 项）

```bash
# 1) 装 debug 包
npx react-native run-android

# 2) 把金样本塞进应用私有目录（debug 包可用 run-as，无需 root）
adb push fixtures/golden-v3.db /data/local/tmp/golden-v3.db
adb shell run-as com.noteapp.taskmaster.spike mkdir -p databases
adb shell run-as com.noteapp.taskmaster.spike cp /data/local/tmp/golden-v3.db databases/v5_tasks.db

# 3) 在调试入口调用 verifyGolden()，看日志里的 RESULT=
```

> **注意**：上面两行的包名与库名是 Spike 当时的值。
> v6 的包名是 `com.noteapp.taskmaster.v6`，库名是 `tasks.db`（不再是 `v5_tasks.db`）。

期望 `RESULT=PASS`，且 5 项全 PASS。任一项 FAIL 就停下来修，不要继续做 UI。

### 验收项（对应 `docs/schema-v3.md` §7）

1. 12 张表行数一致
2. 余额 == 流水净额
3. 孤儿关联数量与期望一致（金样本里故意留了 1 条 `tag_id=999`）
4. 时间格式无异常
5. `PRAGMA integrity_check` = ok

## Spike 剩下三项（M0 之后）

| 项 | 出口 |
|---|---|
| 番茄钟前台计时 + 通知 | 杀进程后仍到点响 |
| 1 个桌面小组件 | 真机可用，数据与主应用一致 |
| OTA 全链路 | 上传 → 下载 → 重启生效 → 回滚上一版 |

## 已知待验证（这三项后来都已在真机上确认）

- `op-sqlite` 的 `location` 参数在 Android 上指向 `databases/` 的确切写法；
- `db.execute()` 返回结构（`rows` / `rowsAffected`）的字段名；
- 模板生成的 RN 版本与 New Architecture 默认开关状态。

> **后续结论**：`execute()` 是 **async**、`executeSync()` 才是同步的。
> 因此本项目形成了一条反直觉的约定——**读操作用同步、写操作用异步**，
> 详见 `src/repo/base.ts`。这是当时踩过的坑，不要凭直觉改回去。
