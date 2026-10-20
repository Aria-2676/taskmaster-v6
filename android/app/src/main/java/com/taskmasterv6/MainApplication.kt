package com.taskmasterv6

import android.app.Application
import java.io.File
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost

class MainApplication : Application(), ReactApplication {

  /**
   * OTA 覆盖包：存在即优先加载，删掉即回落到包内 bundle。
   *
   * 这是「热更能不能成立」的核心开关——路径与判定规则一旦定死，
   * 后续下载/校验/回滚都只是围绕这个文件做文章。
   */
  private fun otaBundleFile(): String? {
    val candidates = listOf(
      File(filesDir, "ota/index.android.bundle"),
      File(getExternalFilesDir(null), "ota/index.android.bundle"),
    )
    return candidates.firstOrNull { it.exists() && it.length() > 0 }?.absolutePath
  }

  override val reactHost: ReactHost by lazy {
    getDefaultReactHost(
      context = applicationContext,
      jsBundleFilePath = otaBundleFile(),
      // 有外部 bundle 时关掉 dev support，否则 debug 包会一直连 Metro、永远读不到文件
      useDevSupport = otaBundleFile() == null,
      packageList =
        PackageList(this).packages.apply {
          add(DevControlPackage())
        },
    )
  }

  override fun onCreate() {
    super.onCreate()
    loadReactNative(this)
  }
}
