// v6 主包预览入口（独立于 main.dart，不影响现有 App）。
//
//   flutter run -t lib/main_v6_preview.dart
//
// 目前是纯假数据的界面骨架，用来验证布局与手感。
import 'package:flutter/material.dart';

import 'app/v6_preview_app.dart';

void main() {
  runApp(const V6PreviewApp());
}
