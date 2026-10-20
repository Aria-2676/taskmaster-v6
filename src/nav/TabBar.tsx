/**
 * 底部 Tab 栏。三个 Tab，与 M1 范围一致。
 *
 * 什么时候显示由 Navigator 决定：**只在 Tab 首页显示**，压栈页面和弹窗时隐藏。
 * 这样压出来的详情页不会带着一条底部栏，视觉上才像「推入了一层」。
 */

import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { usePalette } from '../ui/usePalette';
import { useNavStore } from './store';
import type { TabName } from './routes';

const TABS: ReadonlyArray<{ name: TabName; label: string }> = [
  { name: 'Tasks', label: '任务' },
  { name: 'Points', label: '积分' },
  { name: 'Profile', label: '我的' },
];

export function TabBar(): React.JSX.Element {
  const palette = usePalette();
  const active = useNavStore((s) => s.tab);
  const switchTab = useNavStore((s) => s.switchTab);

  return (
    <View style={[styles.bar, { backgroundColor: palette.tabBg, borderTopColor: palette.border }]}>
      {TABS.map((t) => {
        const on = t.name === active;
        return (
          <Pressable
            key={t.name}
            style={styles.item}
            onPress={() => switchTab(t.name)}
            accessibilityRole="button"
            accessibilityState={{ selected: on }}
          >
            <Text style={[styles.label, { color: on ? palette.primary : palette.tabInactive }]}>{t.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  item: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 10,
  },
  label: {
    fontSize: 14,
  },
});
