package com.taskmasterv6

import android.os.Process
import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

/**
 * 仅用于 Spike 验证：让应用自己杀掉自己。
 *
 * 为什么要它：ColorOS 禁止 shell 杀后台进程（KILL_BACKGROUND_PROCESSES），
 * `am crash` 又会让系统在短时间内拒绝启动该应用的广播接收器，
 * 都无法模拟「进程被系统正常回收」。自杀是唯一干净的等价场景。
 *
 * 另外提供 [updateWidgets]：JS 侧写完数据后主动刷新桌面小组件，
 * 因为 AppWidget 的 `updatePeriodMillis` 系统下限是 30 分钟，等不起。
 */
class DevControlModule(ctx: ReactApplicationContext) : ReactContextBaseJavaModule(ctx) {
  override fun getName(): String = "DevControl"

  @ReactMethod
  fun killSelf() {
    Process.killProcess(Process.myPid())
  }

  /**
   * 刷新所有已添加的桌面小组件实例。
   *
   * 语义上等价于系统下发一次 APPWIDGET_UPDATE。**不会**抛出到 JS：
   * 刷新失败（没有实例 / 组件未注册）不属于调用方需要处理的错误。
   */
  @ReactMethod
  fun updateWidgets() {
    try {
      TaskWidgetProvider.refreshAll(reactApplicationContext)
    } catch (e: Exception) {
      Log.w(TAG, "updateWidgets failed", e)
    }
  }

  private companion object {
    private const val TAG = "DevControl"
  }
}
