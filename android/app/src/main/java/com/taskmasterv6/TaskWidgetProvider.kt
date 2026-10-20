package com.taskmasterv6

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import android.widget.RemoteViews
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * 桌面小组件：只读打开 [DB_NAME]，展示今日任务统计与积分余额。
 *
 * 设计约束（见 docs/migration/schema-v3.md）：
 * 1. 时间列是 **ISO8601 本地时间字符串**（如 `2026-10-20T09:30:00`），不是时间戳。
 *    因此「今日」区间用**字符串区间比较**表达：ISO8601 定长前缀的字典序 == 时间序，
 *    这样能命中 `idx_tasks_cpl_time` 索引，避免全表扫描 + 逐行解析。
 * 2. `is_ok` 是 0/1 整数，`user_points` 只有 `id = 1` 一行。
 * 3. 任何异常（库不存在 / 被迁移 / 表缺失 / 脏数据）都**不允许崩溃**：
 *    统一降级为三个 `—` 占位符，并打一条警告日志。
 *
 * 线程模型：`onUpdate` 与 [refreshAll] 都在调用方线程同步读库。AppWidget 的
 * `ACTION_APPWIDGET_UPDATE` 由主线程投递，单次查询是毫秒级 COUNT 且走索引，
 * 直接同步执行可以避免「RemoteViews 回填晚于系统超时」的坑；不做异步是为了
 * 保证「读到什么就渲染什么」的确定性。
 */
class TaskWidgetProvider : AppWidgetProvider() {

  /**
   * 系统下发刷新时回调（首次添加、`updatePeriodMillis` 到期、手动刷新）。
   *
   * @param context 提供方上下文（application context 语义）
   * @param appWidgetManager 系统小组件管理器
   * @param appWidgetIds 本次需要刷新的所有实例 id
   */
  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray,
  ) {
    // Kotlin 侧 IntArray 非空（平台类型是 `int[]`），只判空数组，不写 == null。
    if (appWidgetIds.isEmpty()) {
      return
    }
    // 读库一次，复用给所有实例：同一时刻多个小组件的统计值必然相同。
    // 构建失败绝不能冒到 AppWidgetManager（会记成应用 ANR/崩溃），直接跳过本次渲染。
    val views = try {
      buildRemoteViews(context)
    } catch (e: Exception) {
      Log.w(TAG, "onUpdate buildRemoteViews failed, skip this round", e)
      return
    }
    for (appWidgetId in appWidgetIds) {
      try {
        appWidgetManager.updateAppWidget(appWidgetId, views)
      } catch (e: Exception) {
        Log.w(TAG, "updateAppWidget failed, id=$appWidgetId", e)
      }
    }
  }

  /**
   * 实例尺寸/选项变化时回调：尺寸变了也要重新渲染，避免文字被裁切后一直不复原。
   */
  override fun onAppWidgetOptionsChanged(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetId: Int,
    newOptions: android.os.Bundle,
  ) {
    // 同上：渲染失败只跳过，不让异常冒到 AppWidgetManager。
    val views = try {
      buildRemoteViews(context)
    } catch (e: Exception) {
      Log.w(TAG, "onAppWidgetOptionsChanged buildRemoteViews failed, id=$appWidgetId", e)
      return
    }
    try {
      appWidgetManager.updateAppWidget(appWidgetId, views)
    } catch (e: Exception) {
      Log.w(TAG, "onAppWidgetOptionsChanged failed, id=$appWidgetId", e)
    }
  }

  companion object {
    private const val TAG = "TaskWidget"

    /** 与 Flutter 版共用同一个库文件，路径由 `context.getDatabasePath` 解析。 */
    private const val DB_NAME = "tasks.db"

    /** 数据不可用时的占位符（EM DASH），与需求约定一致。 */
    private const val PLACEHOLDER = "\u2014"

    /** 查询「今日」区间使用的格式：与库内 ISO8601 本地时间的前 19 位完全对齐。 */
    private const val TIME_PATTERN = "yyyy-MM-dd'T'HH:mm:ss"

    /**
     * 刷新所有已添加到桌面的小组件实例。
     *
     * 供 JS 侧（经 [DevControlModule.updateWidgets]）在数据变更后主动调用，
     * 避免用户必须等到 `updatePeriodMillis` 到期才能看到新数字。
     *
     * @param context 任意 context；内部只用 `getDatabasePath` 与 `AppWidgetManager`
     */
    @JvmStatic
    fun refreshAll(context: Context) {
      try {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val component = ComponentName(context, TaskWidgetProvider::class.java)
        val ids = manager.getAppWidgetIds(component)
        if (ids == null || ids.isEmpty()) {
          // 没有实例是正常状态（用户没添加过），不当作错误。
          return
        }
        val views = buildRemoteViews(context)
        for (id in ids) {
          try {
            manager.updateAppWidget(id, views)
          } catch (e: Exception) {
            Log.w(TAG, "refreshAll updateAppWidget failed, id=$id", e)
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "refreshAll failed", e)
      }
    }

    /**
     * 构造一份完整的 RemoteViews（含点击事件）。
     *
     * @param context 上下文
     * @return 可直接交给 `AppWidgetManager.updateAppWidget` 的视图
     */
    private fun buildRemoteViews(context: Context): RemoteViews {
      val packageName = context.packageName
      val views = RemoteViews(packageName, R.layout.widget_task)
      val snapshot = readSnapshot(context)

      // 每帧渲染都打一条：桌面上的数字没法用 adb 直接读（uiautomator 看不到
      // 非当前页的 RemoteViews），这条日志是「小组件读到的到底是什么」的唯一可验证出口。
      Log.i(TAG, "render todo=${snapshot.todoText} done=${snapshot.doneText} points=${snapshot.pointsText}")

      views.setTextViewText(R.id.widget_todo_value, snapshot.todoText)
      views.setTextViewText(R.id.widget_done_value, snapshot.doneText)
      views.setTextViewText(R.id.widget_points_value, snapshot.pointsText)
      views.setContentDescription(R.id.widget_root, snapshot.contentDescription)

      val launchIntent = buildLaunchPendingIntent(context)
      if (launchIntent != null) {
        views.setOnClickPendingIntent(R.id.widget_root, launchIntent)
      }
      return views
    }

    /**
     * 点击小组件 → 打开主应用。
     *
     * @param context 上下文
     * @return 点击 PendingIntent；解析不到启动 Intent 时返回 null（此时不设置点击）
     */
    private fun buildLaunchPendingIntent(context: Context): PendingIntent? {
      val launchIntent = try {
        context.packageManager.getLaunchIntentForPackage(context.packageName)
      } catch (e: Exception) {
        Log.w(TAG, "getLaunchIntentForPackage failed", e)
        null
      } ?: return null

      // NEW_TASK：从桌面点击进入时必须；CLEAR_TOP + 主 Activity 的 singleTask 保证不叠新实例。
      launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      return try {
        PendingIntent.getActivity(
          context,
          0,
          launchIntent,
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
      } catch (e: Exception) {
        Log.w(TAG, "PendingIntent.getActivity failed", e)
        null
      }
    }

    /**
     * 只读打开数据库并读取三个指标。任何失败都返回全占位符快照。
     *
     * @param context 上下文（用于解析 `databases/` 目录）
     * @return 渲染所需的三段文本
     */
    private fun readSnapshot(context: Context): WidgetSnapshot {
      val dbFile: File = try {
        context.getDatabasePath(DB_NAME)
      } catch (e: Exception) {
        Log.w(TAG, "getDatabasePath failed", e)
        return WidgetSnapshot.unavailable()
      }

      if (!dbFile.exists() || dbFile.length() <= 0L) {
        Log.w(TAG, "database missing: ${dbFile.absolutePath}")
        return WidgetSnapshot.unavailable()
      }

      var db: SQLiteDatabase? = null
      return try {
        // OPEN_READONLY：绝不写库，避免与 RN 侧并发写产生锁竞争或误改数据。
        db = SQLiteDatabase.openDatabase(
          dbFile.absolutePath,
          null,
          SQLiteDatabase.OPEN_READONLY,
        )
        // RN 侧（op-sqlite）持有写事务时，读连接会立刻拿到 SQLITE_BUSY；默认 busy handler
        // 超时为 0 → 直接抛 SQLiteDatabaseLockedException，这一帧就显示成 —。
        // 给 2s 重试窗口，跨过常见的短写事务（PRAGMA 本身会返回一行，必须消费并关闭游标）。
        db?.rawQuery("PRAGMA busy_timeout = 2000", null)?.use { it.moveToFirst() }
        val range = todayRange()
        val todo = countTasks(db, range.first, range.second, SOLVED_NO)
        val done = countTasks(db, range.first, range.second, SOLVED_YES)
        val points = readPoints(db)
        WidgetSnapshot(
          todoText = todo?.toString() ?: PLACEHOLDER,
          doneText = done?.toString() ?: PLACEHOLDER,
          pointsText = points?.toString() ?: PLACEHOLDER,
        )
      } catch (e: Exception) {
        Log.w(TAG, "read database failed", e)
        WidgetSnapshot.unavailable()
      } finally {
        try {
          db?.close()
        } catch (e: Exception) {
          Log.w(TAG, "close database failed", e)
        }
      }
    }

    /**
     * 计算「今天」的半开区间 `[今日 00:00:00, 明日 00:00:00)`，返回可直接做字符串比较的边界。
     *
     * @return first = 区间起点（含），second = 区间终点（不含）
     */
    private fun todayRange(): Pair<String, String> {
      // SimpleDateFormat 非线程安全，每次现建，避免静态实例被并发踩坏。
      val formatter = SimpleDateFormat(TIME_PATTERN, Locale.US)
      // Calendar.getInstance() 已带设备默认时区（本地），与库内「本地时间字符串」语义一致。
      val calendar = Calendar.getInstance()
      calendar.set(Calendar.HOUR_OF_DAY, 0)
      calendar.set(Calendar.MINUTE, 0)
      calendar.set(Calendar.SECOND, 0)
      calendar.set(Calendar.MILLISECOND, 0)
      val start = formatter.format(calendar.time)
      // 用 Calendar 加一天而不是硬加 24 小时，天然处理夏令时与月末跨月。
      calendar.add(Calendar.DAY_OF_YEAR, 1)
      val end = formatter.format(calendar.time)
      return start to end
    }

    /**
     * 统计今日指定完成状态的任务数。
     *
     * SQL：`SELECT COUNT(*) FROM tasks WHERE is_ok = ? AND cpl_time >= ? AND cpl_time < ?`
     * 命中 `idx_tasks_cpl_time`（`is_ok` 单独也有索引）。
     *
     * @param db 只读数据库
     * @param start 区间起点 ISO8601 字符串
     * @param end 区间终点 ISO8601 字符串
     * @param isOk 0 = 待办，1 = 已完成
     * @return 数量；查询异常或为空时返回 null（由调用方降级为占位符）
     */
    private fun countTasks(
      db: SQLiteDatabase,
      start: String,
      end: String,
      isOk: Int,
    ): Int? {
      val sql = "SELECT COUNT(*) FROM tasks " +
        "WHERE is_ok = ? AND cpl_time >= ? AND cpl_time < ?"
      return try {
        db.rawQuery(sql, arrayOf(isOk.toString(), start, end)).use { cursor ->
          if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getInt(0) else null
        }
      } catch (e: Exception) {
        Log.w(TAG, "countTasks failed, is_ok=$isOk", e)
        null
      }
    }

    /**
     * 读取积分余额。
     *
     * SQL：`SELECT points FROM user_points WHERE id = 1`
     *
     * @param db 只读数据库
     * @return 余额；单行表缺行或异常时返回 null
     */
    private fun readPoints(db: SQLiteDatabase): Int? {
      return try {
        db.rawQuery("SELECT points FROM user_points WHERE id = 1", null).use { cursor ->
          if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getInt(0) else null
        }
      } catch (e: Exception) {
        Log.w(TAG, "readPoints failed", e)
        null
      }
    }
  }
}

/**
 * 小组件一次性渲染所需的全部文本。
 *
 * @property todoText 今日待办数文本
 * @property doneText 今日已完成数文本
 * @property pointsText 积分余额文本
 */
internal data class WidgetSnapshot(
  val todoText: String,
  val doneText: String,
  val pointsText: String,
) {
  /** 供无障碍服务朗读的一句话摘要。 */
  val contentDescription: String
    get() = "今日任务：待办 $todoText，已完成 $doneText，积分 $pointsText"

  companion object {
    /** 全部降级为占位符，用于数据库缺失 / 读取失败。 */
    fun unavailable(): WidgetSnapshot = WidgetSnapshot("\u2014", "\u2014", "\u2014")
  }
}

/** `tasks.is_ok` 取值：0 = 未完成。 */
private const val SOLVED_NO = 0

/** `tasks.is_ok` 取值：1 = 已完成。 */
private const val SOLVED_YES = 1
