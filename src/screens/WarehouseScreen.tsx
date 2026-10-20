/**
 * 仓库：已兑换的商品，按**快照 name** 分组展示。
 *
 * 🔴 本页最容易搞错、又最不容易被发现的一点（spec B.5 / F22，v5 有单测守着）：
 *
 *   **卡片上显示的是 `group.latest`（最新那条的快照：图标 / 描述 / 价格），
 *   但点「使用」删掉的是 `group.oldest`（最旧那条）。**
 *   两者**不是同一条记录**，这是有意为之（先消耗囤积，oldest-first）。
 *   搞反了界面看起来完全正常，数据却悄悄错——所以这里**只用**
 *   `pickOldestForUse(group)` 取该删的那条，**不自己 sort、不取 `[0]`**。
 *
 * 另外两点：
 * - 「使用」是**物理删除**：不退还积分、不写 `points_records`、不进回收站
 *   （spec B.5）。所以「余额 == SUM(流水)」的不变量不受影响。
 * - 分组键是**字符串 name 而不是 `shop_item_id`**：商品改名会分裂成两组，
 *   不同商品重名会合并成一组。这是既定行为（spec H6），**不要**去"修"它。
 */

import React, { useEffect, useState } from 'react';
import { Alert, FlatList, Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import { useNavStore } from '../nav/store';
import type { RouteParams } from '../nav/routes';
import { useShopStore } from '../state/shopStore';
import { pickOldestForUse, type WarehouseGroup } from '../core/pointsRules';
import type { PurchasedItemRow } from '../repo/types';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing } from '../ui/theme';
import { shopColorHex, shopIconGlyph } from './ShopScreen';

/** `YYYY-MM-DDTHH:mm:ss.mmm` → `YYYY-MM-DD HH:mm`。存的是本地时间串，直接切，不过 Date。 */
function formatWhen(iso: string): string {
  const date = iso.slice(0, 10);
  const time = iso.slice(11, 16);
  return time.length === 5 ? `${date} ${time}` : date;
}

export default function WarehouseScreen({ params }: { params: RouteParams }): React.JSX.Element {
  void params;

  const palette = usePalette();
  const push = useNavStore((s) => s.push);

  const groups = useShopStore((s) => s.groups);
  const refresh = useShopStore((s) => s.refresh);
  const consume = useShopStore((s) => s.consume);

  const [busyName, setBusyName] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const onUse = (group: WarehouseGroup<PurchasedItemRow>): void => {
    // 该删的是**最旧**那条，与卡片上显示的 latest 不是同一条。
    const target = pickOldestForUse(group);
    Alert.alert(
      `使用「${group.name}」`,
      `将消耗最早兑换的一件（${target.price} 积分），剩余 ${group.count - 1} 件。\n使用不会退还积分，也无法撤销。`,
      [
        { text: '取消', style: 'cancel' },
        {
          text: '使用',
          style: 'destructive',
          onPress: () => {
            void (async () => {
              setBusyName(group.name);
              setNotice(null);
              try {
                const result = await consume(target.id);
                // 传入的是该删的那条 id；store 会再按此刻的分组确认一次。
                setNotice(result.ok ? `已使用「${group.name}」` : result.message ?? '使用失败，请重试');
              } finally {
                setBusyName(null);
              }
            })();
          },
        },
      ],
    );
  };

  const total = groups.reduce((sum, g) => sum + g.count, 0);

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <View style={[styles.header, { backgroundColor: palette.surface, borderColor: palette.border }]}>
        <Text style={[styles.h1, { color: palette.text }]}>我的仓库</Text>
        <Text style={[styles.sub, { color: palette.textDim }]}>
          共 {groups.length} 类 / {total} 件
        </Text>
        <Pressable onPress={() => push('Shop')} accessibilityRole="button">
          <Text style={[styles.link, { color: palette.primary }]}>去商城兑换 ›</Text>
        </Pressable>
      </View>

      {notice !== null && (
        <View style={[styles.notice, { backgroundColor: palette.surfaceAlt }]}>
          <Text style={[styles.noticeText, { color: palette.text }]}>{notice}</Text>
        </View>
      )}

      {groups.length === 0 ? (
        <View style={styles.empty}>
          <Text style={[styles.emptyText, { color: palette.textDim }]}>
            仓库是空的。去积分商城兑换一件吧。
          </Text>
        </View>
      ) : (
        <FlatList
          data={groups}
          keyExtractor={(g) => g.name}
          contentContainerStyle={styles.list}
          renderItem={({ item: group }) => {
            // 图标 / 描述 / 价格一律取 latest——照搬 warehouse_page.dart 的口径。
            const shown = group.latest;
            const busy = busyName === group.name;
            return (
              <View
                style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}
              >
                <View style={[styles.iconBox, { backgroundColor: shopColorHex(shown.color_value) }]}>
                  <Text style={styles.icon}>{shopIconGlyph(shown.icon_name)}</Text>
                </View>

                <View style={styles.info}>
                  <View style={styles.titleRow}>
                    <Text style={[styles.name, { color: palette.text }]}>{group.name}</Text>
                    <View style={[styles.badge, { backgroundColor: palette.surfaceAlt }]}>
                      <Text style={[styles.badgeText, { color: palette.text }]}>×{group.count}</Text>
                    </View>
                  </View>
                  <Text style={[styles.desc, { color: palette.textDim }]}>{shown.description}</Text>
                  <Text style={[styles.meta, { color: palette.textDim }]}>
                    {shown.price} 积分 · 最近兑换 {formatWhen(shown.purchased_at)}
                  </Text>
                </View>

                <Pressable
                  style={[styles.use, { backgroundColor: palette.primary }]}
                  onPress={() => onUse(group)}
                  disabled={busy}
                  accessibilityRole="button"
                >
                  <Text style={[styles.useText, { color: palette.onPrimary }]}>
                    {busy ? '使用中…' : '使用'}
                  </Text>
                </Pressable>
              </View>
            );
          }}
        />
      )}
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
  sub: { marginTop: spacing.xs, fontSize: fontSize.sm },
  link: { marginTop: spacing.sm, fontSize: fontSize.sm },
  notice: { paddingHorizontal: spacing.lg, paddingVertical: spacing.sm },
  noticeText: { fontSize: fontSize.sm },
  list: { padding: spacing.lg, gap: spacing.md },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    borderRadius: radius.md,
    padding: spacing.md,
    borderWidth: StyleSheet.hairlineWidth,
  },
  iconBox: {
    width: 44,
    height: 44,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  icon: { fontSize: fontSize.xl },
  info: { flex: 1, marginLeft: spacing.md },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  name: { fontSize: fontSize.md, fontWeight: '500' },
  badge: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
    borderRadius: radius.pill,
  },
  badgeText: { fontSize: fontSize.xs },
  desc: { marginTop: spacing.xs, fontSize: fontSize.sm, lineHeight: 18 },
  meta: { marginTop: spacing.xs, fontSize: fontSize.xs },
  use: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
  },
  useText: { fontSize: fontSize.sm },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  emptyText: { fontSize: fontSize.sm, textAlign: 'center', lineHeight: 20 },
});
