# 任务管家 V6

Flutter 版 v5 的 **React Native 重写**。做这件事的首要目标是**重获持续热更新能力**
（v5 是 Flutter，无法 OTA；改一行字也要重新发包）。

## 与 v5 的关系

| | v5 | v6（本仓库） |
|---|---|---|
| 技术栈 | Flutter 3.11 / Dart | React Native 0.88 / TypeScript |
| 仓库 | `Aria-2676/note_study`（已冻结为归档，继续承载 v5 更新通道） | `Aria-2676/taskmaster-v6` |
| 包名 | `com.noteapp.taskmaster` | `com.noteapp.taskmaster.v6` |
| 状态 | 停止功能开发 | 开发中 |

两个 App 用**不同的包名**，可以在同一台手机上共存，互不覆盖——这是刻意的选择，
让换栈过程零不可逆风险。

**不做数据兼容**（有意为之）：v6 视作一个**新 App** 来开发，不要求迁移 v5 的数据。
`docs/` 下的 `spec-*.md`、`schema-v3.md`、`business-rules.md` 描述的是 **v5 的行为**，
它们的定位是「参考旧版怎么做的」，不是「v6 必须对齐的契约」。

## 技术栈

- React Native 0.88 + React 19.3 + TypeScript，New Architecture + Hermes（默认开）
- 数据库：`@op-engineering/op-sqlite`
  - 注意它的 `execute()` 是**异步**的，同步版本是 `executeSync()`
  - `executeBatch()` 只返回**总计**的 `rowsAffected`，拿不到每条语句各自的结果
- 状态管理：Zustand（**不使用 React Navigation**，M1 只需底部 Tab + 弹窗，自写约 150 行栈导航）

## 目录结构

```
src/db/     建表 / 建索引 / 首次启动播种 / 连接单例
src/repo/   taskRepo · recycleRepo · tagRepo · pointsRepo · shopRepo + tx 事务原语
src/core/   积分规则 · 循环规则 · 番茄钟
src/ota/    热更新：清单契约（manifest.ts）+ 下载校验回滚（updater.ts）
src/notify/ 通知
tool/       校验脚本（见下）
docs/       路线图 / 裁决记录 / 表结构 / v5 行为规格
```

## 构建与运行

本机（Windows，中文用户名）有几个**必须绕开的坑**，都是实际踩过的：

1. **中文用户名会让 AGP 的 prefab classpath 出现乱码** → 必须把
   `GRADLE_USER_HOME`、`TEMP`、`TMP` 指到 `D:/Dev/tools/` 下的目录。
2. **JDK 用 17**：`D:/Dev/tools/jdk17`。
3. **路径必须写 Windows 风格**（`D:/...`）。Git Bash 风格（`/d/...`）会让
   `adb install` 直接失败。

```bash
npm install                 # 或复用别处已装好的 node_modules
npx tsc --noEmit            # 类型检查：必须 0 错误

cd android
GRADLE_USER_HOME=D:/Dev/tools/gradle-home \
TEMP=D:/Dev/tools/tmp TMP=D:/Dev/tools/tmp \
JAVA_HOME=D:/Dev/tools/jdk17 \
./gradlew assembleDebug
```

真机调试（PCAM00 / ColorOS / Android 11）另有两点：
安装时 ColorOS 会弹「继续安装」需要手动点一下；Metro 掉线后要重新
`adb reverse tcp:8081 tcp:8081`。

## 校验工具

| 命令 | 验的是什么 |
|---|---|
| `python tool/verify_orphan_cleanup.py` | 四条永久删除路径跑完后 `task_tags` 孤儿数必须为 0；外加**两层静态扫描**（用错列 / 漏守卫） |
| `python tool/verify_task_repo_sql.py` | `taskRepo` 的 SQL 语义，含**对照组**证明断言不是空转 |
| `python tool/make_golden_sample.py` | 重建金样本（确定性，多次生成 sha256 一致） |
| `python tool/check_md_blocks.py` | Markdown **渲染**结构（引用块吞段落 / 围栏未闭合 / 列表被吞） |
| `npx jest` | `src/core/__tests__` 下的单测 |

`fixtures/` **不入库**（金样本是二进制，且可确定性重建），
所以校验脚本在样本缺失时会**自动重建**而不是跳过——跳过等于假通过。

这些工具的判据都有**反向测试**：故意注入违规写法，必须报错并退出 1，
否则说明工具在空转。

## 当前进度

- [x] **数据层**：五个仓储、事务原语、建表播种、类型定义
- [ ] **功能接线**：Zustand + UI + 导航 + 真机冒烟

数据层的工作量只占 M1 的三分之一左右，**界面层才是大头**。
详见 `docs/ROADMAP.md`。

## ⚠️ 发版前必须处理的两件事

1. **`App.tsx:28` 的 `OTA_BASE_URL = 'http://127.0.0.1:8099'` 是验证期占位值**，
   发版前必须换成真实的 CDN 地址，否则用户端永远拉不到清单。
2. **v6 必须用自己独立的 `manifest.json`，绝不能去读 v5 的 `update.json`。**
   v5 那份是「整包 APK」清单，被 v6 当成「JS bundle」清单解析会出错。
   反过来说，v5 用户**升级到 v6 的那一次**仍然走 v5 的 `update.json`——
   但推的是 v6 的 **APK 整包**，不是 bundle，这两件事不要混为一谈。

## 文档

- `docs/ROADMAP.md` —— 路线图与里程碑
- `docs/m1-decisions.md` —— 34 条裁决 + 索引表（每条都标注了受影响的代码与文档）
- `docs/schema-v3.md` —— 14 张表的契约
- `docs/business-rules.md` —— 业务规则（含「待核实」项的处理状态）
- `docs/spec-*.md` —— v5 行为规格，历史参考
