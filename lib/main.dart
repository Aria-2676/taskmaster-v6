// v6 主包正式入口。
//
// 和预览入口的关系：
//
//   lib/main.dart              正式版（这个文件）：不写演示数据、启动后检查更新
//   lib/main_v6_preview.dart   开发预览：写演示数据、不联网
//
// （v5 旧入口 `main_v5_legacy.dart` **不在这个仓库里** —— 它跟着已归档的
//   `note_study` 仓库走。这里的代码不引用 `lib/modules/`，两边零交叉。）
//
// 两件事是硬要求，别改：
//   autoSeed: false   —— 正式版首启不能出现"写完 v6 主包的第一屏"这种演示任务
//   checkUpdate: true —— 新包必须保留自更新能力，否则发出去就是最后一版
import 'package:flutter/material.dart';

import 'app/v6_preview_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const V6PreviewApp(autoSeed: false, checkUpdate: true));
}
