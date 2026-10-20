/**
 * 本地通知（番茄钟提醒的最小验证）
 *
 * 目标不是做完整番茄钟，而是验证：
 *  1) 通知渠道能建、能弹；
 *  2) 定时触发（TriggerNotification）在**进程被杀之后**仍然到点响。
 *
 * 第 2 点是 Spike 的硬指标——如果做不到，「到点提醒」在 v6 就不成立。
 */

import notifee, {
  AndroidImportance,
  TriggerType,
  type TimestampTrigger,
} from '@notifee/react-native';
import { Platform } from 'react-native';
import { POMODORO_MODE_LABEL, type PomodoroMode } from '../core/pomodoro';

export const CHANNEL_ID = 'pomodoro';

let channelReady = false;

/** 建渠道（Android 8+ 必须）。重复调用是幂等的。 */
export async function ensureChannel(): Promise<void> {
  if (Platform.OS !== 'android' || channelReady) return;
  await notifee.createChannel({
    id: CHANNEL_ID,
    name: '番茄钟提醒',
    importance: AndroidImportance.HIGH,
    sound: 'default',
    vibration: true,
  });
  channelReady = true;
}

/** Android 13+ 需要运行时通知权限；11 及以下直接返回 true。 */
export async function requestPermission(): Promise<boolean> {
  const settings = await notifee.requestPermission();
  return settings.authorizationStatus >= 1;
}

/**
 * 安排一条 `seconds` 秒后的通知。
 *
 * 返回 notifee 的通知 id，便于取消。
 */
export async function scheduleTestNotification(seconds: number): Promise<string> {
  await ensureChannel();
  await requestPermission();

  const trigger: TimestampTrigger = {
    type: TriggerType.TIMESTAMP,
    timestamp: Date.now() + seconds * 1000,
    // 允许在 doze 下唤醒；Android 12+ 若无精确闹钟权限会退化为不精确
    alarmManager: { allowWhileIdle: true },
  };

  return notifee.createTriggerNotification(
    {
      title: '番茄钟结束',
      body: `${seconds} 秒到了，休息一下`,
      android: {
        channelId: CHANNEL_ID,
        pressAction: { id: 'default' },
        smallIcon: 'ic_launcher',
        importance: AndroidImportance.HIGH,
      },
    },
    trigger,
  );
}

export async function cancelNotification(id: string): Promise<void> {
  await notifee.cancelNotification(id);
}

/** 清空当前应用的全部通知（测试用，避免新旧通知混淆）。 */
export async function cancelAll(): Promise<void> {
  await notifee.cancelAllNotifications();
}

/**
 * 番茄钟**到点**立即弹一条通知。
 *
 * 与 `scheduleTestNotification` 的区别：这里没有 trigger。
 * 前台计时的面板自己盯着墙钟，到点那一刻直接 `displayNotification`——
 * 既避免 trigger 与计时器双份倒计时出现「通知早响 / 晚响」，
 * 也保留 trigger 那条路径继续验证「进程被杀后仍能响」的 Spike 硬指标。
 *
 * @param mode    刚结束的阶段
 * @param minutes 该阶段的计划分钟数，用于正文里告诉用户结束了多久
 * @returns notifee 的通知 id
 */
export async function notifyPomodoroEnd(mode: PomodoroMode, minutes: number): Promise<string> {
  await ensureChannel();
  // Android 13+ 没有 POST_NOTIFICATIONS 权限时通知会被静默丢弃，
  // 面板上「已写入记录」会变成假绿，所以这里必须先确保权限。
  await requestPermission();

  const label = POMODORO_MODE_LABEL[mode];
  const shown = Number.isFinite(minutes) && minutes > 0 ? Math.round(minutes) : 0;
  const body =
    mode === 'work'
      ? `${label} ${shown} 分钟已完成，去休息一下`
      : `${label} ${shown} 分钟已结束，回来继续专注`;

  return notifee.displayNotification({
    title: '番茄钟结束',
    body,
    android: {
      channelId: CHANNEL_ID,
      pressAction: { id: 'default' },
      smallIcon: 'ic_launcher',
      importance: AndroidImportance.HIGH,
    },
  });
}

/** 只用于排查：列出当前待触发的通知。 */
export async function listTriggerNotifications(): Promise<string[]> {
  const list = await notifee.getTriggerNotifications();
  return list.map((t) => `${t.notification.id ?? '?'}@${t.trigger?.type ?? '?'}`);
}
