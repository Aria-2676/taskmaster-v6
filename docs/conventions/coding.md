# 编码与测试规范

> 最后更新：2026-11-01

## 1. 通用

- **先读再改**：没读过的文件不改；不确定就 `Grep`/`Read` 确认，不要凭文件名猜。
- **最小改动**：只做需求需要的事。不要顺手重构、不要加没有调用点的抽象、
  不要为一个用例造工具类。
- **一处语义一处实现**：同一个判断/文案/键名不要在多个页面各写一份。
- **删干净**：确定不用的代码直接删，不要留 `_unused`、注释掉的旧实现、
  “以后可能用”的分支。
- 新增依赖必须写入 `docs/decisions.md`，说明为什么现有依赖不够。能用标准库/现有包就不加。

## 2. Dart / Flutter

- 跟随 `analysis_options.yaml` 与 `flutter_lints`；`dart format` 后再提交。
- 命名：类 `UpperCamelCase`，变量/方法 `lowerCamelCase`，常量 `lowerCamelCase`；
  文件名 `snake_case.dart`。
- 能用 `const` 就用；`build` 里不要做 IO/重计算。
- 状态用 `ChangeNotifier` + `ListenableBuilder`（项目现状），不额外引入状态管理库。
- Provider 作用域：需要跨路由读的 provider 放在 `MaterialApp` 外层，
  弹窗宿主放在内层；路由不在 `home` 子树里，包在 `home` 里会 `ProviderNotFoundException`。
- 页面拆分：页面只负责呈现与转发；持久化/确认逻辑放主壳或 store，避免两处各写一份。
- 平台层组件（弹层、键盘、Insets、SnackBar 持久化）不能只靠 widget test 判断，
  必须真机/模拟器验证，并在交付说明里写“未在真机跑过”或“已跑”。

## 3. 测试

**目录按概念分，不强制镜像 `lib/` 路径。** 例：`CurrencyStore` 在 `lib/app/state/`，
测试在 `test/core/currency/`，因为它是“货币”这个概念的测试。

| 类型 | 放哪 | 用途 |
|---|---|---|
| 纯逻辑/解析/版本 | `test/core/` | 快、稳定，覆盖边界与非法输入 |
| 数据/迁移/插件表 | `test/core/data/`、`test/core/plugin/` | 真 SQLite（ffi） |
| 页面/交互 | `test/app/` | widget test，锁“有/没有这个特征” |
| 打包脚本 | `test/plugin_packaging/` | stdlib unittest，不依赖 pytest |
| 手感/平台层 | 真机/模拟器 | 滚动、拖拽、键盘、弹层、通知 |

**硬规则**

- 新逻辑必须有断言**行为**的测试，不是“跑了一遍没报错”。
- 修 bug 先写一个会红的测试；修完再跑一次确认变绿。**没有反向测试的守卫不算守卫。**
- `testWidgets` 里真实磁盘 IO（写 zip、拷文件、sqflite 落盘）会挂到 10 分钟超时，
  必须包 `tester.runAsync`；但 `runAsync` 会吞异常，断言“表被删了”要查 `sqlite_master`。
- `pumpAndSettle` 遇到无限动画（进度圈）不返回；有 spinner 时不要调它。
- 数据库测试用 `databaseFactoryFfiNoIsolate`，避免假时钟与子 isolate 的时序问题。
- 迁移测试必须造一个**真老库**再打开；只跑新库测不出升级崩溃。
- widget test 通过 ≠ 真机点得着；平台层的坑（如 Android 17 edge-to-edge 弹层热区错位）
  只能真机发现，验收清单要单独标“需真机”。

## 4. 数据 / SQL

- sqflite 裸 SQL，不引入 drift/build_runner；列名用常量。
- 所有写操作明确事务边界；跨表删除/恢复必须在同一个事务里。
- 迁移写法：`newVersion > version` 抛；`oldVersion < N` 补一步；每步能单独跑通。
- 插件表：`plg_<id>_<suffix>`；`plg_migrations` 独立版本；删除插件数据按前缀守卫，
  防“迁移记录被篡改时删到主包表”。
- 删除 API 不留默认值；`toRecycle` 必须显式传。
- 查询必须有 `limit`；插件 bridge 的 `task.list` 上限 200、`db.select` 默认 100/上限 500。
- 外部数据解析 fail-soft：顶层结构错 → 抛；单字段错 → 丢字段。
- 时间：任务日期用 `yyyy-MM-dd` 字符串；需要时间戳时明确本地/UTC，不混用。

## 5. 界面

- 设置页只放“怎么工作”，分组固定：外观 / 任务 / 插件 / 数据 / 关于。
- **没有的功能不占位**：宁可不显示，也不放一个点不动的灰项。
- 状态长在对应的入口上（如插件数量挂在「插件市场」行），不要在页面顶部单开一行。
- 插件模式下不画主包 `+`；如果某个模式需要新建，由插件自己提供入口（如计划模式的“这天加一条”）。
- 删除确认、回收站开关、清空等规则只写在壳层/一个入口；页面通过回调请求，不复制规则。
- SnackBar 只承载一句话通知；带 `action` 的 SnackBar 默认不会自动消失，
  需要自动消失就显式设置或改用对话框/页面内提示。
- 弹层（`showModalBottomSheet`）在部分 Android 版本有画面/热区错位；快捷选择优先用居中
  `showDialog`。`DraggableScrollableSheet` 的三个关闭开关默认要关掉，防“改到一半拖没了”。
- 删除用 `Dismissible` 时：`confirmDismiss` 只返回 bool，不改全局状态；副作用放 `onDismissed`。
- 长列表注意懒加载与视口：widget test 默认 800×600 放不下手机页面，必要时设 360×780。
- 文案要具体：不要“操作成功”，写清“已移入回收站 / 已彻底删除”。

## 6. 插件

- `plugin.json` 必填：`id`、`name`、`version`、`contract`、`entry`；`id` 只允许
  `[a-z][a-z0-9_]{1,31}`；`entry` 必须是包内相对 `.html` 路径。
- 权限默认空集；读/写/删分开；新增权限必须同步 `PermissionCopy`，否则界面露出“未知权限：xxx”。
- 插件不直连数据库：只用 bridge；自己的数据只能用 manifest 声明的 `storage` 表；
  `db.update`/`db.delete` 必须带 `where`；永不执行插件传来的 SQL。
- 事件：manifest 声明 `hooks` 才能收到；payload 只给算结果需要的字段（不含描述）；
  没挂载时用 `event.pending` + `event.ack`，**必须按 id 幂等**，不 ack 会重复投递。
- 版本号只能从 `system.info` 取，**不许在 HTML 里写死**；升级后页面要刷新（清缓存 + 换 key）。
- 首页声明 `home` 不是准入：声明 = 默认进快捷切换；没声明 = 默认收起但用户可打开。
- 插件包只走仓库分发（`plugins/packages/`），APK 里只放 `index.json`；
  随包只保留“断网必须可用且没它 App 不能用”的例外。
- 打包必须幂等：时间戳固定、行尾归一化、内容一致就 reuse；索引 sha/size 由脚本算，不手写。
- 插件 id/路径会进目录名与表前缀，校验必须严格；下载后必须验 sha256。

## 7. 脚本与配置

- 批量替换/脚本改配置：脚本里 `assert` 匹配数，改完 `grep` 复核；
  不允许“没匹配上也打印成功”。
- 测试命令单独确认退出码（`> log 2>&1; echo $?`），**不要用管道接 `&&` 提交**，
  管道会把失败盖成 0。
- PowerShell 脚本存 UTF-8 **带 BOM**；`-File` 不做表达式解析，数组参数用纯 ASCII 包装脚本 +
  UTF-8 JSON 传入。
- 文件名只用 ASCII（内容可中文）；中文路径会让 `push_via_api.ps1` 的 git 调用失败。
- 本机路径（JDK/Gradle/keystore）不写进仓库配置；用环境变量或本机脚本。
- 提交前 `git status --untracked-files=all`，确认没有 `*.db`、备份、token、密钥。

## 8. 依赖与平台

- Android 单平台；iOS 目录只是骨架，不构建、不声称可用。
- 不引入需要应用商店的能力（Play Dynamic Feature、商店审核豁免等）。
- 不接服务器、不产生持续费用；分发只用 GitHub/Gitee/jsDelivr。
- 升级 Flutter/Dart/AGP/Gradle 前先看 `docs/decisions.md` 与构建环境记录；
  Java 25 与 Gradle 8.14 不兼容是已知坑。

## 9. 提交前最小检查

```bash
flutter analyze lib
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
    NO_PROXY=127.0.0.1,localhost flutter test
git status --short
```

- `analyze` 无 error；info/warning 看一眼，不新增。
- 全量测试通过，记录总数（对比上一轮只增不减）。
- 本轮没验证的东西（真机手感、未复现 bug、跳过的平台）写进交付说明。
