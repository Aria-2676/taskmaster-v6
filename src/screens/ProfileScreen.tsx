/**
 * 「我的」Tab 首页。
 *
 * 只列入入口，不在这里直接渲染业务数据（积分余额、任务统计之类）：
 * 数据层刚落地，这里写死读库会让后面接真数据的人再来删一遍。
 */

import React from 'react';
import { Pressable, SafeAreaView, ScrollView, StyleSheet, Text } from 'react-native';
import { useNavStore } from '../nav/store';
import type { RouteName } from '../nav/routes';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing } from '../ui/theme';

const ENTRIES: ReadonlyArray<{ route: RouteName; label: string }> = [
  { route: 'Settings', label: '设置' },
  { route: 'Recycle', label: '回收站' },
  { route: 'Tags', label: '标签' },
  { route: 'Pomodoro', label: '番茄钟' },
];

export function ProfileScreen(): React.JSX.Element {
  const palette = usePalette();
  const push = useNavStore((s) => s.push);

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={[styles.h1, { color: palette.text }]}>我的</Text>
        {ENTRIES.map((e) => (
          <Pressable
            key={e.route}
            style={[styles.item, { backgroundColor: palette.surface, borderColor: palette.border }]}
            onPress={() => push(e.route)}
            accessibilityRole="button"
          >
            <Text style={[styles.label, { color: palette.text }]}>{e.label}</Text>
            <Text style={[styles.chevron, { color: palette.textDim }]}>›</Text>
          </Pressable>
        ))}
        <Text style={[styles.foot, { color: palette.textDim }]}>
          业务数据（任务数、积分、连续打卡）等数据层就绪后在这里补齐。
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  body: { padding: spacing.lg },
  h1: { fontSize: fontSize.xl, fontWeight: '500', marginBottom: spacing.lg },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderRadius: radius.md,
    padding: spacing.lg,
    marginBottom: spacing.sm,
    borderWidth: StyleSheet.hairlineWidth,
  },
  label: { fontSize: fontSize.md },
  chevron: { fontSize: fontSize.lg },
  foot: { marginTop: spacing.md, fontSize: fontSize.xs, lineHeight: 18 },
});
