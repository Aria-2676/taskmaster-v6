# 任务 · 6.5.0 清单升级（独立实体 + 模板 + 转任务）

> 日期：2026-11-16 ｜ 状态：done（模拟器已验）
> 协调者：用户 ｜ 实现者：WorkBuddy ｜ 核查者：用户

## 范围

- 要做：
  1. 清单有**自己的数据**：`plg_list_lists`（清单）+ `plg_list_items`（条目），
     不再"读主包任务"
  2. 清单库：清单列表（名字 / 未完成数 / 模板标记）+ 新建
  3. 清单内页：条目勾选、添加、删除、清空已完成、进度
  4. 模板：清单可存为模板，从模板新建
  5. 清单项**转任务**（建任务 + 该项标完成）
- 明确不做：
  - 任务反向关联清单（要主包加字段，留到 6.6 一起看）
  - 清单共享（多人/多设备，架构上不支持）

## 涉及文件/目录

- `plugins/src/list_mode/plugin.json`（storage 声明 + 版本 2.0.0）
- `plugins/src/list_mode/index.html`（重写）
- `plugins/src/list_mode/query.html`（新增，供今日页取"未完成数"）
- `assets/plugins/index.json` + `plugins/packages/*.zip`（重新打包）
- `docs/ROADMAP.md` 4.5（6.5 完成后标记）

## 依赖

- 前置：6.2 数据交互层（已有）、备忘插件验证过的 storage 用法
- 需要裁决：无

## 验收

- 机器判定：`flutter analyze lib`、全量测试、打包幂等、索引与包内清单一致
- 人判定（模拟器）：
  1. 新建清单 → 加 3 条 → 勾 1 条 → 进度显示 1/3
  2. 存为模板 → 模板区出现 → 从模板新建 → 条目复制过来
  3. 条目转任务 → 主包任务列表出现同名任务
  4. 重启 App → 数据都在
- 验收清单：`docs/acceptance/2026-11-16-list-upgrade.md`（完成后补）

## 风险

- 数据：新表，首次安装自动建；旧版（只读任务）未存任何数据，无迁移负担
- 真机：WebView 里的滚动与输入框（键盘弹起）要真机验

## 交接区

### 已完成（模拟器逐项验过，2026-11-16 02:26）

- 清单库 / 清单内页 / 模板 / 转任务 全部跑通
- 数据持久化：重开 App 后清单和条目都在
- 从模板新建：3 条条目复制过来、完成状态不复制（0/3）

### 已知坑

1. **`window.prompt` 在 webview_flutter 里会弹 Android 原生灰色对话框**，
   标题是「The page at file:// says:」，和 App 观感完全割裂。
   已在 2.0.1 换成页面内 `askText` 弹层。
2. **构建参数与模拟器不匹配**：模拟器上原先装的是 preview 包（versionCode 10108），
    `flutter build apk --release` 产的是 6108，直接装会 `INSTALL_FAILED_VERSION_DOWNGRADE`。
   先 `adb uninstall` 再装。
3. **模拟器 GPU 会进入黑屏状态**：Dart 层已启动（日志有 `[home] 内置`）但画面不渲染。
   `adb reboot` 后恢复，不是代码问题。

### 未验证
- 中文输入（adb 只能打 ASCII，名字用了 Camping 验证流程）
- 长清单（几十条）的滚动与性能
