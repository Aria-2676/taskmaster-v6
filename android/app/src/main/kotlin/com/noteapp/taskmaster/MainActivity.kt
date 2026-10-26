package com.noteapp.taskmaster

import io.flutter.embedding.android.FlutterActivity

// V5 在这里挂了「桌面小组件」的桥接（getIntentExtras / refresh_widget），
// V6 没有小组件能力，那套通道没有接收方，一并去掉。
class MainActivity : FlutterActivity()
