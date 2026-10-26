# 任务管家 V6

字段可配置、插件可扩的任务管理应用。Flutter，Android 单平台（iOS 明确放弃）。

## 和 V5 的关系

| | 仓库 | 状态 |
|---|---|---|
| V5 | [`Aria-2676/note_study`](https://github.com/Aria-2676/note_study) | **冻结**，只在需要修老用户问题时动手。它的 `update.json` 停在 6.0.0 |
| V6 | 本仓库 | 活跃开发 |

两边是**独立的两条线**：代码零交叉引用，更新清单各一份，Release 各一套。
V5 装过的用户会在更新弹窗里看到 6.0.0（一次可选升级，可以「跳过此版本」），
升级后任务列表是空的 —— **V5 的数据不迁移**，理由见 `docs/self-update-v5-to-v6.md`。

> 本仓库曾经放过一次 React Native 换栈的存档。换栈已否决（见 `docs/platform-decision.md`），
> 那份代码对 Flutter 零复用，已清空。

## 跑起来

```bash
flutter pub get
flutter run                          # 正式版入口（不写演示数据、检查更新）
flutter run -t lib/main_v6_preview.dart   # 预览：写演示数据、不联网
flutter test                         # 441 条
```

## 结构

```
lib/app/            主包外壳：首页、编辑层、侧边栏、插件市场、关于
lib/core/data/      v6 数据库与 schema
lib/core/plugin/    插件体系：清单、安装、桥接、事件、私有表
lib/core/updater/   自更新：查清单 → 多源下载 → 系统安装器
lib/core/field/     字段目录与用户偏好
docs/               设计文档，先看 INDEX.md
```

## 发版

1. `pubspec.yaml` 的 `version` 抬 build 号（`6.x.y+6001`…），versionCode 是覆盖安装的唯一判据
2. `flutter build apk --release`，确认签名是 `D:\Dev\keystore\` 那把
3. 产物传 GitHub Release
4. **最后**改 `update.json`（`latest.version` + `downloads` 的 url / sha256 / sizeBytes）

顺序不能反：清单先改、包没传，用户点更新会拿到死链。
