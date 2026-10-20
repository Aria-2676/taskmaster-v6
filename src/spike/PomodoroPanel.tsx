/**
 * 番茄钟面板（Spike 第 6 项：前台计时）
 *
 * 验收目标只有三件事：
 *  1. 前台倒计时走得准——基于**墙钟**而不是每 tick 自减；
 *  2. 归零时写 `pomodoro_records`（is_completed=1，actual_seconds 是真实经历秒数）；
 *  3. 归零时弹通知 + 顺手推一次桌面小组件。
 *
 * 「自减为什么不行」：250ms 一次 `remaining -= 0.25`，误差会累积；
 * 更糟的是后台被节流后 tick 直接停摆，回前台显示的还是离开前的数字。
 * 这里只记一个 `endsAt = Date.now() + remaining * 1000`，每次 tick 用 `Date.now()` 重算。
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { NativeModules, Pressable, StyleSheet, Text, View } from 'react-native';
import { openDatabase } from '../db';
import { countRecords, insertRecord, nowLocalIso, readSettings } from '../db/pomodoro';
import { notifyPomodoroEnd } from '../notify';
import {
  DEFAULT_POMODORO_SETTINGS,
  POMODORO_MODE_LABEL,
  durationSeconds,
  formatRemaining,
  nextMode,
  remainingSeconds,
  type PomodoroMode,
  type PomodoroSettings,
} from '../core/pomodoro';

/** tick 间隔。250ms 足够让秒数跳动看起来是准的，又不会太频繁吵醒主线程。 */
const TICK_MS = 250;

type RunState = 'idle' | 'running' | 'paused';

export default function PomodoroPanel(): React.JSX.Element {
  const [mode, setMode] = useState<PomodoroMode>('work');
  const [settings, setSettings] = useState<PomodoroSettings>(DEFAULT_POMODORO_SETTINGS);
  const [remaining, setRemaining] = useState<number>(
    () => durationSeconds('work', DEFAULT_POMODORO_SETTINGS),
  );
  const [runState, setRunState] = useState<RunState>('idle');
  const [completedWorkCount, setCompletedWorkCount] = useState<number>(0);
  const [recordCount, setRecordCount] = useState<number>(0);
  const [message, setMessage] = useState<string>('未开始');
  const [error, setError] = useState<string | null>(null);

  // 计时相关的可变量放 ref：它们参与 interval 回调，用 state 会读到闭包里的旧值。
  const modeRef = useRef<PomodoroMode>('work');
  const endsAtRef = useRef<number | null>(null);
  const startTimeRef = useRef<string>('');
  /** 当前这段「运行中」的起点；暂停时把这个区间结清。 */
  const segmentStartRef = useRef<number | null>(null);
  /** 已结清的真实运行毫秒（不含暂停时长），用来算 actual_seconds。 */
  const elapsedMsRef = useRef<number>(0);

  /** 切换阶段时同步 ref 与 state，避免只改一边导致下一步判错。 */
  const applyMode = useCallback((next: PomodoroMode) => {
    modeRef.current = next;
    setMode(next);
  }, []);

  const errText = useCallback((e: unknown): string => {
    return e instanceof Error ? `${e.message}\n${e.stack ?? ''}` : String(e);
  }, []);

  /** 把当前运行区间的真实时长结清到 `elapsedMsRef`，并结束该区间。 */
  const accumulateElapsed = useCallback((): void => {
    if (segmentStartRef.current !== null) {
      elapsedMsRef.current += Date.now() - segmentStartRef.current;
      segmentStartRef.current = null;
    }
  }, []);

  /** 推桌面小组件。旧原生包里没有 `updateWidgets`，可选链静默跳过；有异常也不能影响验收。 */
  const refreshWidgets = useCallback((): void => {
    try {
      NativeModules.DevControl?.updateWidgets?.();
    } catch (e) {
      console.log('WIDGET_REFRESH_FAILED', String(e));
    }
  }, []);

  // 首屏：读设置与已有记录条数。金样本里可能没有设置行，readSettings 会兜底到默认值。
  useEffect(() => {
    try {
      const db = openDatabase();
      const loaded = readSettings(db);
      setSettings(loaded);
      setRecordCount(countRecords(db));
      setRemaining(durationSeconds('work', loaded));
      setMessage(
        `设置：专注 ${loaded.workDuration} / 短休 ${loaded.shortBreakDuration} / ` +
          `长休 ${loaded.longBreakDuration} 分钟，每 ${loaded.longBreakInterval} 个专注进长休`,
      );
    } catch (e) {
      setError(`读取番茄钟设置失败，已用默认值：${errText(e)}`);
    }
  }, [errText]);

  const finish = useCallback((): void => {
    // 先停表再干活：后续是异步 IO，不能让 interval 在写库期间第二次触发归零。
    setRunState('idle');
    accumulateElapsed();
    endsAtRef.current = null;
    setRemaining(0);

    const finishedMode = modeRef.current;
    const endTime = nowLocalIso();
    const startTime = startTimeRef.current.length > 0 ? startTimeRef.current : endTime;
    const plannedSeconds = durationSeconds(finishedMode, settings);
    // 真实经历秒数：暂停时长不计入（用户没在「经历」番茄钟），也不向上取整虚报时长。
    const actualSeconds = Math.floor(elapsedMsRef.current / 1000);
    elapsedMsRef.current = 0;
    segmentStartRef.current = null;
    startTimeRef.current = '';

    let total = recordCount;
    try {
      const db = openDatabase();
      insertRecord(db, {
        mode: finishedMode,
        durationSeconds: plannedSeconds,
        actualSeconds,
        startTime,
        endTime,
        isCompleted: true,
      });
      total = countRecords(db);
      setRecordCount(total);
    } catch (e) {
      setError(`写入番茄钟记录失败：${errText(e)}`);
    }

    notifyPomodoroEnd(finishedMode, plannedSeconds / 60).catch((e) => {
      setError(`通知失败：${errText(e)}`);
    });
    refreshWidgets();

    if (finishedMode === 'work') {
      const done = completedWorkCount + 1;
      const next = nextMode(done, settings);
      setCompletedWorkCount(done);
      applyMode(next);
      setRemaining(durationSeconds(next, settings));
      setMessage(
        `专注完成（第 ${done} 个），下一个：${POMODORO_MODE_LABEL[next]}。` +
          `已写入记录，共 ${total} 条`,
      );
    } else {
      applyMode('work');
      setRemaining(durationSeconds('work', settings));
      setMessage(`${POMODORO_MODE_LABEL[finishedMode]}结束，回到专注。已写入记录，共 ${total} 条`);
    }
  }, [
    accumulateElapsed,
    applyMode,
    completedWorkCount,
    errText,
    recordCount,
    refreshWidgets,
    settings,
  ]);

  /** 每 tick 用墙钟重算剩余；归零则结算。 */
  const tick = useCallback((): void => {
    const endsAt = endsAtRef.current;
    if (endsAt === null) return;
    const left = remainingSeconds(endsAt, Date.now());
    setRemaining(left);
    if (left <= 0) finish();
  }, [finish]);

  // interval 的生命周期跟 runState 绑：暂停 / 卸载由 effect cleanup 统一清理，
  // 不手工 stopTimer，避免「忘了清」和「清两遍」。
  useEffect(() => {
    if (runState !== 'running') return undefined;
    const id = setInterval(tick, TICK_MS);
    tick();
    return () => clearInterval(id);
  }, [runState, tick]);

  const onStart = useCallback((): void => {
    if (runState === 'running') return;
    setError(null);
    const secondsLeft = remaining > 0 ? remaining : durationSeconds(modeRef.current, settings);
    // 继续 / 首次：仅在从 idle 起步时重置累计值与开始时间。
    if (runState === 'idle') {
      elapsedMsRef.current = 0;
      startTimeRef.current = nowLocalIso();
    }
    endsAtRef.current = Date.now() + secondsLeft * 1000;
    segmentStartRef.current = Date.now();
    setRemaining(secondsLeft);
    setRunState('running');
    setMessage(`${POMODORO_MODE_LABEL[modeRef.current]}计时中…`);
  }, [remaining, runState, settings]);

  const onPause = useCallback((): void => {
    if (runState !== 'running' || endsAtRef.current === null) return;
    setError(null);
    // 按顺序：先取真实剩余 → 结清累计 → 掐掉 endsAt，最后才切状态。
    // 掐掉 endsAt 放在切状态之前，是为了让「切换生效前那一次残留 tick」直接 return，
    // 不会拿着旧 endsAt 再算一遍（极端情况下可能被误判成归零而写记录）。
    const left = remainingSeconds(endsAtRef.current ?? Date.now(), Date.now());
    accumulateElapsed();
    endsAtRef.current = null;
    setRunState('paused');
    setRemaining(left);
    setMessage(`已暂停，剩余 ${formatRemaining(left)}`);
  }, [accumulateElapsed, runState]);

  const onReset = useCallback((): void => {
    setRunState('idle');
    setError(null);
    endsAtRef.current = null;
    segmentStartRef.current = null;
    elapsedMsRef.current = 0;
    startTimeRef.current = '';
    setRemaining(durationSeconds(modeRef.current, settings));
    setMessage('已重置');
  }, [settings]);

  const startLabel = runState === 'paused' ? '继续' : '开始';

  return (
    <View style={styles.card}>
      <Text style={styles.h2}>番茄钟</Text>
      <Text style={styles.line}>
        当前：{POMODORO_MODE_LABEL[mode]}　已完成专注：{completedWorkCount} 个
      </Text>
      <Text style={styles.big}>{formatRemaining(remaining)}</Text>
      <Text style={styles.line}>pomodoro_records 条数：{recordCount}</Text>
      <View style={styles.row}>
        <Pressable style={styles.btn} onPress={onStart} disabled={runState === 'running'}>
          <Text style={styles.btnText}>{startLabel}</Text>
        </Pressable>
        <Pressable style={styles.btn} onPress={onPause} disabled={runState !== 'running'}>
          <Text style={styles.btnText}>暂停</Text>
        </Pressable>
        <Pressable style={[styles.btn, styles.danger]} onPress={onReset}>
          <Text style={styles.btnText}>重置</Text>
        </Pressable>
      </View>
      <Text style={styles.msg}>{message}</Text>
      {error !== null ? <Text style={styles.err}>{error}</Text> : null}
    </View>
  );
}

// 数值取自 rn/App.tsx，保证两张卡片视觉一致。
const styles = StyleSheet.create({
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 10,
    padding: 12,
    marginBottom: 12,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#DDDDDD',
  },
  h2: { fontSize: 14, fontWeight: '500', color: '#111111', marginBottom: 8 },
  big: { fontSize: 40, fontWeight: '500', color: '#111111', marginVertical: 6 },
  line: { fontSize: 13, color: '#333333', lineHeight: 22 },
  row: { flexDirection: 'row', marginTop: 10, gap: 8 },
  btn: {
    flex: 1,
    backgroundColor: '#185FA5',
    paddingVertical: 9,
    borderRadius: 8,
    alignItems: 'center',
  },
  danger: { backgroundColor: '#A32D2D' },
  btnText: { color: '#FFFFFF', fontSize: 13 },
  msg: { marginTop: 10, fontSize: 12, color: '#5F5E5A' },
  err: { marginTop: 8, fontSize: 12, color: '#A32D2D' },
});
