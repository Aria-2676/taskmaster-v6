/**
 * 设置页。
 *
 * 目前只做两件已经能落地的事：主题三档切换 + 开发者面板入口。
 *
 * ⚠️ schema 里播种了 16 个设置键，但**没有一次全做**：settingsStore 由另一个人并行实现，
 * 现在先写一堆读写会跟它撞车。等 `src/state/settingsStore.ts` 落地后，按下面的 TODO 补齐，
 * 读写一律走 `src/repo/settingsRepo.ts`（`getSetting` / `setSetting`），不要自己写 SQL。
 *
 * TODO(settingsStore 落地后补齐)：
 *   allowCompletePastTasks / allowEditPastTasks / enabledCreateFields / enabledEditFields /
 *   lastCompletionFilter / lastPriorityFilter / lastRecurrenceFilter / lastTagFilterId /
 *   profilePinnedSettings / rememberFilters / settingsPinnedSettings / taskCreateMode /
 *   taskEditMode / taskSortOption / taskViewMode
 *   —— 以及把 themeMode 从内存里的 themeStore 换成落库的真实读写（schema 里已有该键）。
 */

import React from 'react';
import { Pressable, SafeAreaView, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useNavStore } from '../nav/store';
import { useThemeStore } from '../state/themeStore';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing, type ThemeMode } from '../ui/theme';

const THEME_OPTIONS: ReadonlyArray<{ mode: ThemeMode; label: string }> = [
  { mode: 'system', label: '跟随系统' },
  { mode: 'light', label: '浅色' },
  { mode: 'dark', label: '深色' },
];

export function SettingsScreen(): React.JSX.Element {
  const palette = usePalette();
  const push = useNavStore((s) => s.push);
  const mode = useThemeStore((s) => s.mode);
  const setMode = useThemeStore((s) => s.setMode);

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={[styles.h1, { color: palette.text }]}>设置</Text>

        <View style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}>
          <Text style={[styles.h2, { color: palette.text }]}>主题</Text>
          <View style={styles.row}>
            {THEME_OPTIONS.map((o) => {
              const on = o.mode === mode;
              return (
                <Pressable
                  key={o.mode}
                  style={[
                    styles.chip,
                    {
                      backgroundColor: on ? palette.primary : palette.surfaceAlt,
                      borderColor: on ? palette.primary : palette.border,
                    },
                  ]}
                  onPress={() => setMode(o.mode)}
                  accessibilityRole="button"
                  accessibilityState={{ selected: on }}
                >
                  <Text style={[styles.chipText, { color: on ? palette.onPrimary : palette.text }]}>
                    {o.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
          <Text style={[styles.hint, { color: palette.textDim }]}>
            主题模式目前只存在内存里，重启 App 会回到「跟随系统」；等 settingsStore 接线后落库。
          </Text>
        </View>

        <Pressable
          style={[styles.item, { backgroundColor: palette.surface, borderColor: palette.border }]}
          onPress={() => push('DevPanel')}
          accessibilityRole="button"
        >
          <Text style={[styles.label, { color: palette.text }]}>开发者面板</Text>
          <Text style={[styles.chevron, { color: palette.textDim }]}>›</Text>
        </Pressable>
        <Text style={[styles.hint, { color: palette.textDim }]}>
          OTA 状态与操作、启动健康计数、番茄钟前台计时、金样本验收都在这里。
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  body: { padding: spacing.lg },
  h1: { fontSize: fontSize.xl, fontWeight: '500', marginBottom: spacing.lg },
  card: {
    borderRadius: radius.md,
    padding: spacing.lg,
    marginBottom: spacing.lg,
    borderWidth: StyleSheet.hairlineWidth,
  },
  h2: { fontSize: fontSize.md, fontWeight: '500', marginBottom: spacing.md },
  row: { flexDirection: 'row', gap: spacing.sm },
  chip: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
  },
  chipText: { fontSize: fontSize.sm },
  hint: { marginTop: spacing.sm, fontSize: fontSize.xs, lineHeight: 18 },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderRadius: radius.md,
    padding: spacing.lg,
    borderWidth: StyleSheet.hairlineWidth,
  },
  label: { fontSize: fontSize.md },
  chevron: { fontSize: fontSize.lg },
});
