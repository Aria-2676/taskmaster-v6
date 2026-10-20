/**
 * 开发者面板 —— Spike 验收控制台，从根目录 App.tsx **原样**搬过来的。
 *
 * 为什么留着：下面几块都是真机验证过的能力，也是排查线上 OTA 问题的**唯一手段**。
 * 真实 App 顶上来之后不能把它们删掉，改成从「设置」页进（普通用户看不到）。
 *
 * 内容：
 *  1) OTA 状态与操作（检查更新 / 下载并应用 / 回滚）
 *  2) 启动健康计数（连续 3 次启动没标记健康就自动回滚）
 *  3) 通知（定时触发 + 杀进程，验证「进程被杀之后仍能响」）
 *  4) 番茄钟前台计时（到期写 pomodoro_records + 弹通知）
 *  5) 金样本验收结果
 *
 * ⚠️ `noteBoot()` / `markHealthy()` **故意不在这里**，它们跑在外壳 App.tsx 里：
 * 启动计数是「每次 App 启动一次」的语义，如果面板每次挂载都记一次，
 * 打开三次面板就会把一个好包误判成坏包并自动回滚。这里只读回计数展示。
 */

import React, { useCallback, useEffect, useState } from 'react';
import { NativeModules, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, View } from 'react-native';
import { verifyGolden, formatReport, type CheckResult } from '../spike/verifyGolden';
import { GOLDEN_EXPECTED } from '../spike/expected';
import { checkForUpdate, downloadAndApply, readState, rollback, type OtaState } from '../ota/updater';
import type { OtaManifest } from '../ota/manifest';
import { cancelAll, ensureChannel, listTriggerNotifications, scheduleTestNotification } from '../notify';
import PomodoroPanel from '../spike/PomodoroPanel';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing } from '../ui/theme';

// ⚠️ 验证期占位值，发版前必须换成真实 CDN 地址。
const OTA_BASE_URL = 'http://127.0.0.1:8099';
const APP_VERSION = '6.0.0';
const LOCAL_BUILD = 1;

/** 连续这么多次启动没被 markHealthy 清零，noteBoot() 就自动回滚。与 updater.ts 一致。 */
const BOOT_ROLLBACK_THRESHOLD = 3;

/**
 * 外壳在本次进程启动时记下的 noteBoot() 结果。
 *
 * 用模块级变量而不是 store：这是「本次进程发生过什么」的一次性事实，
 * 不需要订阅，DevPanel 挂载时读一次就够。
 */
let bootNotice: string | null = null;

/** 由外壳 App.tsx 调用，把「已自动回滚」这类启动期事实带给面板。 */
export function recordBootNotice(text: string): void {
  bootNotice = text;
}

export default function DevPanelScreen(): React.JSX.Element {
  const palette = usePalette();
  const [results, setResults] = useState<CheckResult[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [state, setState] = useState<OtaState | null>(null);
  const [message, setMessage] = useState('就绪');
  const [manifest, setManifest] = useState<OtaManifest | null>(null);
  const [busy, setBusy] = useState(false);
  const [notifyMsg, setNotifyMsg] = useState('—');
  /** 本次进程启动时 noteBoot() 的结论（比如「已自动回滚」）。 */
  const [bootNoticeText, setBootNoticeText] = useState<string | null>(() => bootNotice);

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

    // noteBoot() 是异步的，外壳可能还没跑完用户就点进来了，挂载时再取一次。
    setBootNoticeText(bootNotice);
    refresh().catch((e) => setMessage(`OTA 状态读取失败: ${String(e)}`));

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
  const bootCount = state?.bootCount ?? 0;

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={[styles.h1, { color: palette.text }]}>开发者面板</Text>

        {/* 1) OTA 状态与操作 */}
        <View style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}>
          <Text style={[styles.h2, { color: palette.text }]}>OTA</Text>
          <Text style={[styles.line, { color: palette.text }]}>
            外部 bundle 生效：{state?.active ? '是' : '否'}
          </Text>
          <Text style={[styles.line, { color: palette.text }]}>
            build：{state?.build ?? '—'}　version：{state?.version ?? '—'}
          </Text>
          <Text style={[styles.line, { color: palette.text }]}>
            应用时间：{state?.appliedAt ?? '—'}
          </Text>
          <View style={styles.row}>
            <Pressable
              style={[styles.btn, { backgroundColor: palette.primary }]}
              onPress={onCheck}
              disabled={busy}
            >
              <Text style={[styles.btnText, { color: palette.onPrimary }]}>检查更新</Text>
            </Pressable>
            <Pressable
              style={[styles.btn, { backgroundColor: palette.primary }]}
              onPress={onApply}
              disabled={busy}
            >
              <Text style={[styles.btnText, { color: palette.onPrimary }]}>下载并应用</Text>
            </Pressable>
            <Pressable
              style={[styles.btn, { backgroundColor: palette.danger }]}
              onPress={onRollback}
              disabled={busy}
            >
              <Text style={[styles.btnText, { color: palette.onPrimary }]}>回滚</Text>
            </Pressable>
          </View>
          <Text style={[styles.msg, { color: palette.textDim }]}>{message}</Text>
        </View>

        {/* 2) 启动健康计数：连续 3 次启动没被 markHealthy 清零就自动回滚 */}
        <View style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}>
          <Text style={[styles.h2, { color: palette.text }]}>启动健康计数</Text>
          <Text style={[styles.line, { color: palette.text }]}>
            启动计数：{bootCount} / {BOOT_ROLLBACK_THRESHOLD}
          </Text>
          <Text style={[styles.line, { color: bootCount > 0 ? palette.danger : palette.text }]}>
            距自动回滚还剩：{Math.max(BOOT_ROLLBACK_THRESHOLD - bootCount, 0)} 次启动
          </Text>
          {bootNoticeText !== null ? (
            <Text style={[styles.line, { color: palette.danger }]}>{bootNoticeText}</Text>
          ) : null}
          <Text style={[styles.msg, { color: palette.textDim }]}>
            每次启动由外壳 noteBoot() 加一，首屏渲染成功后 markHealthy() 清零。
            积到 {BOOT_ROLLBACK_THRESHOLD} 说明这个包一直没能健康跑完，自动删掉外部 bundle 回到包内版本。
          </Text>
        </View>

        {/* 3) 通知 */}
        <View style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}>
          <Text style={[styles.h2, { color: palette.text }]}>通知</Text>
          <Text style={[styles.line, { color: palette.text }]}>{notifyMsg}</Text>
          <View style={styles.row}>
            <Pressable
              style={[styles.btn, { backgroundColor: palette.primary }]}
              onPress={onSchedule}
              disabled={busy}
            >
              <Text style={[styles.btnText, { color: palette.onPrimary }]}>10 秒后提醒</Text>
            </Pressable>
            <Pressable style={[styles.btn, { backgroundColor: palette.danger }]} onPress={onKill}>
              <Text style={[styles.btnText, { color: palette.onPrimary }]}>杀掉本进程</Text>
            </Pressable>
          </View>
        </View>

        {/* 4) 番茄钟前台计时 */}
        <PomodoroPanel />

        {/* 5) 金样本验收 */}
        <View style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}>
          <Text style={[styles.h2, { color: palette.text }]}>金样本验收</Text>
          <Text style={[styles.mono, { color: palette.text }]}>{report}</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  body: { padding: spacing.lg },
  h1: { fontSize: fontSize.lg, fontWeight: '500', marginBottom: spacing.md },
  h2: { fontSize: fontSize.sm, fontWeight: '500', marginBottom: spacing.sm },
  card: {
    borderRadius: radius.md,
    padding: spacing.md,
    marginBottom: spacing.md,
    borderWidth: StyleSheet.hairlineWidth,
  },
  line: { fontSize: fontSize.sm, lineHeight: 22 },
  row: { flexDirection: 'row', marginTop: spacing.sm, gap: spacing.sm },
  btn: {
    flex: 1,
    paddingVertical: 9,
    borderRadius: radius.sm,
    alignItems: 'center',
  },
  btnText: { fontSize: fontSize.sm },
  msg: { marginTop: spacing.sm, fontSize: fontSize.xs, lineHeight: 18 },
  mono: { fontSize: fontSize.xs, lineHeight: 18, fontFamily: 'monospace' },
});
