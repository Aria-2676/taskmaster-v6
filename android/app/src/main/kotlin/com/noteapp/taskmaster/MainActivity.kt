package com.noteapp.taskmaster

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// V5 在这里挂了「桌面小组件」的桥接（getIntentExtras / refresh_widget），
// V6 没有小组件能力，那套通道没有接收方，一并去掉。
//
// 现在只挂一条：把备份文件存到系统「下载/任务管家」。
// 为什么要走原生：App 私有目录（Android/data/<pkg>/files）用户在文件管理器里
// 看不见，而这套东西唯一的出口是"分享"。存一份到公开下载目录，用户插上电脑
// 或者用文件管理器就能直接拿到 —— Android 10+ 用 MediaStore 写，不需要任何权限。
class MainActivity : FlutterActivity() {
    private val channelName = "taskmaster/export"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        if (path.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("bad_args", "缺少 path 或 name", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(File(path), name))
                        } catch (error: Exception) {
                            // 原始错误照实抛回去：上层要显示"为什么失败"，
                            // 别在这儿翻译成一句人话再吞掉。
                            result.error("save_failed", error.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveToDownloads(source: File, name: String): String {
        if (!source.exists()) throw IllegalArgumentException("源文件不存在：${source.path}")

        val relativeDir = Environment.DIRECTORY_DOWNLOADS + "/任务管家"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/zip")
                put(MediaStore.Downloads.RELATIVE_PATH, relativeDir)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("系统没有给出可写的下载目录")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("打不开下载目录的写入流")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return "$relativeDir/$name"
        }

        // Android 10 以下：直接写公开目录（这条路径需要 WRITE_EXTERNAL_STORAGE，
        // 没有权限就会在这里失败，错误照实抛给上层）
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "任务管家",
        )
        if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("建不了下载子目录")
        val target = File(dir, name)
        source.copyTo(target, overwrite = true)
        return "$relativeDir/$name"
    }
}
