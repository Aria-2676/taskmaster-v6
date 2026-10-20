/**
 * 回收站：恢复 / 只恢复单个实例 / 永久删除 / 清空。
 *
 * 🔴 **删除必须二次确认**（H12 裁决）：
 *
 *   **单条永久删除**和**清空回收站**都要确认，不是只确认清空——
 *   Flutter 版恰好相反（清空有确认、单条没有），误触即永久丢失、不可逆。
 *   确认信息由 `recycleRepo` 提供（`confirmPermanentDelete` / `confirmClearRecycleBin`），
 *   本页只负责弹框，**不自己拼"要不要确认"的判断**。
 *
 * 其他照实说的点：
 * - **上限提示用 `recycleBinLimitHint()`**，不硬编码 10（spec H11）。
 *   并且**没有时间过期**——不是「保留 N 天」，是「只留最近 N 条」，
 *   超出上限的最旧条目在删入新任务时**立即**被物理删除。
 * - **永久删除不退还积分**（spec D.7）：既不动 `points_records` 也不动 `user_points`，
 *   否则「删任务 → 清回收站」就能刷分。界面文案照实说。
 * - **恢复循环任务会按原始 `cplTime` 回补实例**（spec H3，既有缺陷、M1 照搬）：
 *   生成器窗口无下界，删掉很久以前的每日任务再恢复会一次性补出一大堆实例，
 *   所以恢复前**明确提示**，不要悄悄补齐。
 * - 「只恢复此实例」**不是**「恢复到今天」：它保持原始日期、把 `recurrence` 置为
 *   `none`，不触发生成（spec D.5）。
 */

import React, { useEffect, useState } from 'react';
import { Alert, FlatList, Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import type { RouteParams } from '../nav/routes';
import { useRecycleStore } from '../state/recycleStore';
import type { OpResult } from '../state/contracts';
import {
  confirmClearRecycleBin,
  confirmPermanentDelete,
  recycleBinLimitHint,
} from '../repo/recycleRepo';
import type { Recurrence, RecycledTaskRow } from '../repo/types';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing } from '../ui/theme';

/** 重复规则的中文名。仅展示用，取值与 `Recurrence`（没有 yearly）一致。 */
const RECURRENCE_LABEL: Readonly<Record<Recurrence, string>> = {
  none: '不重复',
  daily: '每天',
  weekly: '每周',
  monthly: '每月',
};

/** `YYYY-MM-DDTHH:mm:ss.mmm` → `YYYY-MM-DD HH:mm`。存的是本地时间串，直接切，不过 Date。 */
function formatWhen(iso: string): string {
  const date = iso.slice(0, 10);
  const time = iso.slice(11, 16);
  return time.length === 5 ? `${date} ${time}` : date;
}

export default function RecycleScreen({ params }: { params: RouteParams }): React.JSX.Element {
  void params;

  const palette = usePalette();

  const items = useRecycleStore((s) => s.items);
  const refresh = useRecycleStore((s) => s.refresh);
  const restore = useRecycleStore((s) => s.restore);
  const restoreSingle = useRecycleStore((s) => s.restoreSingle);
  const permanentDelete = useRecycleStore((s) => s.permanentDelete);
  const clearAll = useRecycleStore((s) => s.clearAll);

  const [busyId, setBusyId] = useState<number | null>(null);
  const [busyClear, setBusyClear] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    refresh();
  }, [refresh]);

  /** 统一的结果提示：失败信息由 store 给出中文，不自己编。 */
  const report = (result: OpResult, fallback: string): void => {
    setNotice(result.ok ? fallback : result.message ?? '操作失败，请重试');
  };

  /** 跑一个 store 动作并维护 busy 态。四个动作共用，避免各写一份 try/finally。 */
  const withBusy = async (
    id: number,
    action: () => Promise<OpResult>,
    onDone: (result: OpResult) => void,
  ): Promise<void> => {
    setBusyId(id);
    try {
      onDone(await action());
    } finally {
      setBusyId(null);
    }
  };

  const onRestore = (row: RecycledTaskRow): void => {
    if (row.recurrence === 'none') {
      void withBusy(row.id, () => restore(row.id), r => report(r, `已恢复「${row.title}」`));
      return;
    }
    // spec H3：回补窗口无下界，恢复旧循环任务会一次生成很多实例。先说清楚。
    Alert.alert(
      `恢复「${row.title}」`,
      `这是一个${RECURRENCE_LABEL[row.recurrence]}任务。恢复后会按原始排期（${formatWhen(row.cpl_time)}）` +
        '补齐后续循环实例，可能一次生成较多任务。\n\n只想恢复这一个实例，请用「仅此实例」。',
      [
        { text: '取消', style: 'cancel' },
        {
          text: '恢复并补齐',
          onPress: () =>
            void withBusy(row.id, () => restore(row.id), r =>
              report(r, `已恢复「${row.title}」并补齐循环实例`),
            ),
        },
      ],
    );
  };

  const onRestoreSingle = (row: RecycledTaskRow): void => {
    void withBusy(row.id, () => restoreSingle(row.id), r =>
      report(r, `已恢复「${row.title}」的单个实例（保持原日期、不再循环）`),
    );
  };

  /** 单条永久删除：**必须**二次确认（H12）。 */
  const onPermanentDelete = (row: RecycledTaskRow): void => {
    const confirm = confirmPermanentDelete(row.id);
    if (confirm.count === 0) {
      setNotice('该条目已不在回收站中');
      return;
    }
    Alert.alert(
      confirm.action,
      `「${row.title}」将被永久删除，无法恢复，也不会退还已获得的积分。`,
      [
        { text: '取消', style: 'cancel' },
        {
          text: confirm.action,
          style: 'destructive',
          onPress: () =>
            void withBusy(row.id, () => permanentDelete(row.id), r =>
              report(r, `已永久删除「${row.title}」`),
            ),
        },
      ],
    );
  };

  /** 清空回收站：同样要二次确认（H12）。 */
  const onClearAll = (): void => {
    const confirm = confirmClearRecycleBin();
    if (confirm.count === 0) {
      setNotice('回收站已经是空的');
      return;
    }
    Alert.alert(
      confirm.action,
      `将永久删除 ${confirm.count} 个任务，无法恢复，也不会退还已获得的积分。`,
      [
        { text: '取消', style: 'cancel' },
        {
          text: confirm.action,
          style: 'destructive',
          onPress: () => {
            void (async () => {
              setBusyClear(true);
              setNotice(null);
              try {
                report(await clearAll(), '回收站已清空');
              } finally {
                setBusyClear(false);
              }
            })();
          },
        },
      ],
    );
  };

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <View style={[styles.header, { backgroundColor: palette.surface, borderColor: palette.border }]}>
        <Text style={[styles.h1, { color: palette.text }]}>回收站</Text>
        <Text style={[styles.hint, { color: palette.textDim }]}>
          {recycleBinLimitHint()}，没有时间过期；删入新任务时，超出上限的最旧条目会被立即物理删除。
        </Text>
        <Text style={[styles.count, { color: palette.textDim }]}>当前 {items.length} 条</Text>
      </View>

      {notice !== null && (
        <View style={[styles.notice, { backgroundColor: palette.surfaceAlt }]}>
          <Text style={[styles.noticeText, { color: palette.text }]}>{notice}</Text>
        </View>
      )}

      {items.length === 0 ? (
        <View style={styles.empty}>
          <Text style={[styles.emptyText, { color: palette.textDim }]}>回收站是空的。</Text>
        </View>
      ) : (
        <FlatList
          data={items}
          keyExtractor={(row) => String(row.id)}
          contentContainerStyle={styles.list}
          renderItem={({ item: row }) => {
            const busy = busyId === row.id;
            const recurring = row.recurrence !== 'none';
            return (
              <View
                style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}
              >
                <Text style={[styles.title, { color: palette.text }]}>{row.title}</Text>
                <Text style={[styles.meta, { color: palette.textDim }]}>
                  原排期 {formatWhen(row.cpl_time)}
                  {recurring ? ` · ${RECURRENCE_LABEL[row.recurrence]}` : ''}
                </Text>
                <Text style={[styles.meta, { color: palette.textDim }]}>
                  删除于 {formatWhen(row.deleted_at)}
                </Text>

                <View style={styles.actions}>
                  <Pressable
                    style={[styles.btn, { backgroundColor: palette.primary }]}
                    onPress={() => onRestore(row)}
                    disabled={busy}
                    accessibilityRole="button"
                  >
                    <Text style={[styles.btnText, { color: palette.onPrimary }]}>恢复</Text>
                  </Pressable>

                  {recurring && (
                    <Pressable
                      style={[styles.btn, { backgroundColor: palette.surfaceAlt, borderColor: palette.border }]}
                      onPress={() => onRestoreSingle(row)}
                      disabled={busy}
                      accessibilityRole="button"
                    >
                      <Text style={[styles.btnText, { color: palette.text }]}>仅此实例</Text>
                    </Pressable>
                  )}

                  <Pressable
                    style={[styles.btn, { backgroundColor: palette.surfaceAlt, borderColor: palette.border }]}
                    onPress={() => onPermanentDelete(row)}
                    disabled={busy}
                    accessibilityRole="button"
                  >
                    <Text style={[styles.btnText, { color: palette.danger }]}>永久删除</Text>
                  </Pressable>
                </View>
              </View>
            );
          }}
        />
      )}

      <View style={[styles.footer, { borderColor: palette.border }]}>
        <Pressable
          style={[styles.clearBtn, { backgroundColor: palette.danger }]}
          onPress={onClearAll}
          disabled={busyClear || items.length === 0}
          accessibilityRole="button"
        >
          <Text style={[styles.clearText, { color: palette.onPrimary }]}>
            {busyClear ? '清空中…' : '清空回收站'}
          </Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  header: {
    padding: spacing.lg,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  h1: { fontSize: fontSize.xl, fontWeight: '500' },
  hint: { marginTop: spacing.sm, fontSize: fontSize.xs, lineHeight: 18 },
  count: { marginTop: spacing.xs, fontSize: fontSize.xs },
  notice: { paddingHorizontal: spacing.lg, paddingVertical: spacing.sm },
  noticeText: { fontSize: fontSize.sm },
  list: { padding: spacing.lg, gap: spacing.md },
  card: {
    borderRadius: radius.md,
    padding: spacing.md,
    borderWidth: StyleSheet.hairlineWidth,
  },
  title: { fontSize: fontSize.md, fontWeight: '500' },
  meta: { marginTop: spacing.xs, fontSize: fontSize.xs },
  actions: { flexDirection: 'row', gap: spacing.sm, marginTop: spacing.md },
  btn: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
  },
  btnText: { fontSize: fontSize.sm },
  footer: {
    padding: spacing.lg,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  clearBtn: {
    alignItems: 'center',
    paddingVertical: spacing.md,
    borderRadius: radius.md,
  },
  clearText: { fontSize: fontSize.md },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  emptyText: { fontSize: fontSize.sm, textAlign: 'center' },
});
