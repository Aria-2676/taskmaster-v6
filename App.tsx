/**
 * Spike 控制台：OTA 闭环 + 通知 + 番茄钟 + 金样本验收。
 *
 * 四块：
 *  1) OTA 状态与操作（检查 / 下载应用 / 回滚）
 *  2) 启动计数（连续 3 次没标记健康就自动回滚）
 *  3) 番茄钟前台计时（到期写 pomodoro_records + 弹通知）
 *  4) 金样本验收结果
 */

import React, { useCallback, useEffect, useState } from 'react';
import { NativeModules, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, View } from 'react-native';
import { verifyGolden, formatReport, type CheckResult } from './src/spike/verifyGolden';
import { GOLDEN_EXPECTED } from './src/spike/expected';
import {
  checkForUpdate,
  downloadAndApply,
  markHealthy,
  noteBoot,
  readState,
  rollback,
  type OtaState,
} from './src/ota/updater';
import type { OtaManifest } from './src/ota/manifest';
import { cancelAll, ensureChannel, listTriggerNotifications, scheduleTestNotification } from './src/notify';
import PomodoroPanel from './src/spike/PomodoroPanel';

const OTA_BASE_URL = 'http://127.0.0.1:8099';
const APP_VERSION = '6.0.0';
const LOCAL_BUILD = 1;

export default function App(): React.JSX.Element {
  const [results, setResults] = useState<CheckResult[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [state, setState] = useState<OtaState | null>(null);
  const [message, setMessage] = useState('就绪');
  const [manifest, setManifest] = useState<OtaManifest | null>(null);
  const [busy, setBusy] = useState(false);
  const [notifyMsg, setNotifyMsg] = useState('—');

  const refresh = useCallback(async () => {
    setState(await readState());
  }, []);

  useEffect(() => {
    try {
      const r = verifyGolden(GOLDEN_EXPECTED);
      setResults(r);
      console.log('SPIKE_REPORT\n' + formatReport(r));

      // 数据校验完成后顺手推一次桌面小组件：AppWidget 的 updatePeriodMillis
      // 系统下限是 30 分钟，靠系统广播等不到「刚改完就可见」。
      // 旧原生包里没有 updateWidgets 方法，可选链静默跳过；绝不影响验收流程。
      try {
        NativeModules.DevControl?.updateWidgets?.();
      } catch (e) {
        console.log('WIDGET_REFRESH_FAILED', String(e));
      }
    } catch (e) {
      setError(e instanceof Error ? `${e.message}\n${e.stack ?? ''}` : String(e));
    }

    (async () => {
      const boot = await noteBoot();
      if (boot.rolledBack) {
        setMessage('检测到连续启动失败，已自动回滚到包内版本');
      }
      await refresh();
      setTimeout(() => {
        markHealthy().catch(() => undefined);
      }, 3000);
    })().catch((e) => setMessage(`OTA 初始化失败: ${String(e)}`));

    ensureChannel().catch((e) => setNotifyMsg(`渠道创建失败: ${String(e)}`));
    console.log('DEVCTRL at mount=', !!NativeModules.DevControl);
  }, [refresh]);

  const onCheck = async () => {
    setBusy(true);
    setMessage('检查中…');
    const r = await checkForUpdate(OTA_BASE_URL, APP_VERSION, LOCAL_BUILD);
    setBusy(false);
    if (r.ok) {
      setManifest(r.manifest);
      setMessage(`发现 bundle ${r.manifest.bundle.version} (build ${r.manifest.bundle.build})`);
    } else {
      setManifest(null);
      setMessage(`无可用更新：${r.reason}`);
    }
  };

  const onApply = async () => {
    if (!manifest) {
      setMessage('请先检查更新');
      return;
    }
    setBusy(true);
    setMessage('下载中…');
    const r = await downloadAndApply(manifest);
    setBusy(false);
    await refresh();
    if (r.ok) {
      setMessage(`已应用 build ${r.build}（${(r.bytes / 1024).toFixed(0)}KB），重启后生效`);
    } else {
      setMessage(`应用失败：${r.reason}`);
    }
  };

  const onRollback = async () => {
    setBusy(true);
    await rollback();
    await refresh();
    setBusy(false);
    setMessage('已删除外部 bundle，重启后回到包内版本');
  };

  const onSchedule = async () => {
    try {
      await cancelAll();
      const id = await scheduleTestNotification(10);
      const pending = await listTriggerNotifications();
      setNotifyMsg(`已安排 #${id}（10 秒后）｜待触发 ${pending.length} 条`);
    } catch (e) {
      setNotifyMsg(`安排失败: ${e instanceof Error ? e.message : String(e)}`);
    }
  };

  const onKill = () => {
    const dev = NativeModules.DevControl;
    console.log('DEVCTRL present=', !!dev);
    if (dev?.killSelf) dev.killSelf();
    else setNotifyMsg('调试模块不可用（需重新编译原生）');
  };

  const report = error ? `RESULT=ERROR\n${error}` : formatReport(results);

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={styles.h1}>Spike 控制台</Text>

        <View style={styles.card}>
          <Text style={styles.h2}>OTA</Text>
          <Text style={styles.line}>外部 bundle 生效：{state?.active ? '是' : '否'}</Text>
          <Text style={styles.line}>
            build：{state?.build ?? '—'}　version：{state?.version ?? '—'}
          </Text>
          <Text style={styles.line}>启动计数：{state?.bootCount ?? 0} / 3</Text>
          <View style={styles.row}>
            <Pressable style={styles.btn} onPress={onCheck} disabled={busy}>
              <Text style={styles.btnText}>检查更新</Text>
            </Pressable>
            <Pressable style={styles.btn} onPress={onApply} disabled={busy}>
              <Text style={styles.btnText}>下载并应用</Text>
            </Pressable>
            <Pressable style={[styles.btn, styles.danger]} onPress={onRollback} disabled={busy}>
              <Text style={styles.btnText}>回滚</Text>
            </Pressable>
          </View>
          <Text style={styles.msg}>{message}</Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.h2}>通知</Text>
          <Text style={styles.line}>{notifyMsg}</Text>
          <View style={styles.row}>
            <Pressable style={styles.btn} onPress={onSchedule} disabled={busy}>
              <Text style={styles.btnText}>10 秒后提醒</Text>
            </Pressable>
            <Pressable style={[styles.btn, styles.danger]} onPress={onKill}>
              <Text style={styles.btnText}>杀掉本进程</Text>
            </Pressable>
          </View>
        </View>

        <PomodoroPanel />

        <View style={styles.card}>
          <Text style={styles.h2}>金样本验收</Text>
          <Text style={styles.mono}>{report}</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#F7F7F5' },
  body: { padding: 16 },
  h1: { fontSize: 18, fontWeight: '500', color: '#111111', marginBottom: 12 },
  h2: { fontSize: 14, fontWeight: '500', color: '#111111', marginBottom: 8 },
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 10,
    padding: 12,
    marginBottom: 12,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#DDDDDD',
  },
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
  mono: { fontSize: 12, lineHeight: 18, color: '#222222', fontFamily: 'monospace' },
});
