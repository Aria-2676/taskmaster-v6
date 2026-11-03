# 竖屏锁定 + 番茄钟通知栏倒计时（2026-11-03）

## 任务

1. 设置里加「竖屏锁定」开关（可选，默认锁竖屏）。
2. 番茄钟运行时，通知栏显示常驻倒计时通知（系统 chronometer，App 不刷秒）。

## 设计

### 竖屏锁定

- 键 `ui.lock_portrait`（bool，默认开）。
- 生效：App 层读设置 → `SystemChrome.setPreferredOrientations`。
  锁 = `[portraitUp]`；不锁 = `DeviceOrientation.values`（恢复跟随系统）。
- 设置页加 `SwitchListTile`，切换即时生效并持久化。

### 通知倒计时

- 新增 `NotificationSink.showCountdown({id,title,body,endsAt,channelId})`，
  底层用 `AndroidNotificationDetails(usesChronometer, chronometerCountDown, when=endsAtMillis,
  ongoing, onlyAlertOnce, showWhen)`。
- 番茄钟 store：start/resume/next 显示；pause/reset/advance/settle 取消。
- 用**独立通知 id**（与到点提醒 0x7071 分开），到点提醒照旧。
- minSdk 21：chronometer countdown 需要 API 24，老设备降级为普通显示（可接受）。

## 红线

- 不引入前台服务（到点提醒已由 AlarmManager 兜住，进程被杀照样响）。
- 不每秒刷通知 —— chronometer 由系统自维护，App 只在状态切换时更新一次。
- 通知失败不冒泡、不阻断计时（沿用现有 `_scheduleNotification` 的兜底）。
