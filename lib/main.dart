// v6 主包正式入口。
//
// 和另外两个入口的关系：
//
//   lib/main.dart              正式版（这个文件）：不写演示数据、启动后检查更新
//   lib/main_v6_preview.dart   开发预览：写演示数据、不联网
//   lib/main_v5_legacy.dart    v5 旧界面，只在需要对照时用
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
