/**
 * 积分商城：商品列表 + 兑换。
 *
 * 对应 spec-points-shop.md B 章，三个容易搞错的地方：
 *
 * 1. **余额不足必须明确提示，不能静默失败**。兑换是「扣分 + 写流水 + 写已购快照」
 *    三步同事务（spec B.3），余额不足时是**零写入**——即仓库里不会出现商品、
 *    也不会产生流水。所以界面上「点了没反应」是正确的后端行为，
 *    但用户必须看到原因，否则会以为 App 坏了。
 * 2. **图标名只能用 `SHOP_ICON_NAMES` 里那 28 个**（`shopRepo` 导出）。
 *    未命中会**静默降级**成购物袋，所以这里也不自造名字：
 *    统一先过 `resolveShopIcon()` 再查字形表。
 * 3. **`color_value` 是 ARGB 整数**，与 `tags.color`（`'#RRGGBB'` 字符串）
 *    是两种类型，**不能共用解析函数**（spec B.1 / F16）。本文件的
 *    `shopColorHex` 只服务商品色，别拿去解析标签色。
 *
 * 商品**没有编辑 / 删除入口**（spec B.4 / F23），本页也不提供。
 */

import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  FlatList,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useNavStore } from '../nav/store';
import type { RouteParams } from '../nav/routes';
import { useShopStore } from '../state/shopStore';
import { usePointsStore } from '../state/pointsStore';
import { FALLBACK_SHOP_ICON, resolveShopIcon } from '../repo/shopRepo';
import type { ShopItemRow } from '../repo/types';
import { usePalette } from '../ui/usePalette';
import { fontSize, radius, spacing } from '../ui/theme';

/**
 * Material 图标名 → 字形。
 *
 * 项目没装图标库（依赖里没有 vector-icons），所以这里用 emoji 兜底。
 * **键必须与 `SHOP_ICON_NAMES` 的 28 个名字逐字一致**——写错了不会报错，
 * 只会静默显示成购物袋。取值前一律先过 `resolveShopIcon()`。
 */
const SHOP_ICON_GLYPH: Readonly<Record<string, string>> = {
  shopping_bag: '🛍️',
  card_giftcard: '🎁',
  star: '⭐',
  favorite: '❤️',
  emoji_events: '🏆',
  local_cafe: '☕',
  restaurant: '🍽️',
  cake: '🍰',
  icecream: '🍦',
  sports_esports: '🎮',
  movie: '🎬',
  music_note: '🎵',
  book: '📚',
  sports: '⚽',
  fitness_center: '🏋️',
  flight: '✈️',
  beach_access: '🏖️',
  pets: '🐾',
  shopping_cart: '🛒',
  phone_iphone: '📱',
  laptop: '💻',
  headphones: '🎧',
  watch: '⌚',
  camera: '📷',
  lightbulb: '💡',
  eco: '🌱',
  local_florist: '💐',
  spa: '💆',
};

/** 取图标字形。未命中图标名 → 兜底购物袋（与仓储的静默降级一致）。 */
export function shopIconGlyph(iconName: string): string {
  return SHOP_ICON_GLYPH[resolveShopIcon(iconName)] ?? SHOP_ICON_GLYPH[FALLBACK_SHOP_ICON];
}

/**
 * `shop_items.color_value`（**ARGB 整数**）→ `#RRGGBB`。
 *
 * ⚠️ 只用于商品色。`tags.color` 是字符串，走 `parseTagColorArgb()`，
 * 两者**不可混用**（spec F16）。
 * `>>> 0` 是必须的：alpha 为 FF 时该整数在 JS 里是负数，直接取位会算错。
 */
export function shopColorHex(colorValue: number): string {
  const rgb = (colorValue >>> 0) & 0x00ffffff;
  return `#${rgb.toString(16).padStart(6, '0')}`;
}

export default function ShopScreen({ params }: { params: RouteParams }): React.JSX.Element {
  // params 目前不用（商城无需入参），但 Navigator 一律传，这里照收。
  void params;

  const palette = usePalette();
  const push = useNavStore((s) => s.push);

  const items = useShopStore((s) => s.items);
  const purchased = useShopStore((s) => s.purchased);
  const refresh = useShopStore((s) => s.refresh);
  const purchase = useShopStore((s) => s.purchase);

  const balance = usePointsStore((s) => s.balance);
  const refreshPoints = usePointsStore((s) => s.refresh);

  const [busyId, setBusyId] = useState<number | null>(null);
  /** 兑换结果的就地提示。成功也提示——否则用户不知道分扣到哪去了。 */
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    refresh();
    refreshPoints();
  }, [refresh, refreshPoints]);

  /** 每个商品已兑换几次（按快照里的 `shop_item_id` 数，不涉及 SQL）。 */
  const boughtCount = useMemo(() => {
    const counts = new Map<number, number>();
    for (const p of purchased) {
      if (p.shop_item_id === null) continue;
      counts.set(p.shop_item_id, (counts.get(p.shop_item_id) ?? 0) + 1);
    }
    return counts;
  }, [purchased]);

  const onBuy = async (item: ShopItemRow): Promise<void> => {
    // 余额不足在按钮上就已经表达（禁用 + 文案），这里再兜一次：
    // store 内部是零写入，不会「扣了分没拿到商品」，但必须让用户知道原因。
    if (balance < item.price) {
      Alert.alert('积分不足', `「${item.name}」需要 ${item.price} 积分，当前余额 ${balance} 积分。`);
      return;
    }
    setBusyId(item.id);
    setNotice(null);
    try {
      const result = await purchase(item.id);
      if (result.ok) {
        setNotice(`已兑换「${item.name}」，可在仓库里查看`);
      } else {
        // message 由 store 给出（余额不足 / 商品不存在 / 异常中文），不自己编。
        Alert.alert('兑换失败', result.message ?? '兑换失败，请重试');
      }
    } finally {
      setBusyId(null);
    }
  };

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: palette.bg }]}>
      <View style={[styles.header, { backgroundColor: palette.surface, borderColor: palette.border }]}>
        <Text style={[styles.h1, { color: palette.text }]}>积分商城</Text>
        <Text style={[styles.balance, { color: palette.primary }]}>{balance} 积分</Text>
        <Pressable onPress={() => push('Warehouse')} accessibilityRole="button">
          <Text style={[styles.link, { color: palette.primary }]}>我的仓库 ›</Text>
        </Pressable>
      </View>

      {notice !== null && (
        <View style={[styles.notice, { backgroundColor: palette.surfaceAlt }]}>
          <Text style={[styles.noticeText, { color: palette.success }]}>{notice}</Text>
        </View>
      )}

      {items.length === 0 ? (
        <View style={styles.empty}>
          <Text style={[styles.emptyText, { color: palette.textDim }]}>
            还没有商品。首次启动会自动创建 8 个默认商品。
          </Text>
        </View>
      ) : (
        <FlatList
          data={items}
          keyExtractor={(item) => String(item.id)}
          contentContainerStyle={styles.list}
          renderItem={({ item }) => {
            const afford = balance >= item.price;
            const busy = busyId === item.id;
            const count = boughtCount.get(item.id) ?? 0;
            return (
              <View
                style={[styles.card, { backgroundColor: palette.surface, borderColor: palette.border }]}
              >
                <View style={[styles.iconBox, { backgroundColor: shopColorHex(item.color_value) }]}>
                  <Text style={styles.icon}>{shopIconGlyph(item.icon_name)}</Text>
                </View>

                <View style={styles.info}>
                  <Text style={[styles.name, { color: palette.text }]}>{item.name}</Text>
                  <Text style={[styles.desc, { color: palette.textDim }]}>{item.description}</Text>
                  <Text style={[styles.price, { color: palette.text }]}>{item.price} 积分</Text>
                  {count > 0 && (
                    <Text style={[styles.count, { color: palette.textDim }]}>
                      已兑换 {count} 次
                    </Text>
                  )}
                </View>

                <Pressable
                  style={[
                    styles.buy,
                    {
                      backgroundColor: afford ? palette.primary : palette.surfaceAlt,
                      borderColor: afford ? palette.primary : palette.border,
                    },
                  ]}
                  onPress={() => void onBuy(item)}
                  disabled={busy}
                  accessibilityRole="button"
                >
                  <Text style={[styles.buyText, { color: afford ? palette.onPrimary : palette.textDim }]}>
                    {busy ? '兑换中…' : afford ? '兑换' : '积分不足'}
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
  balance: { marginTop: spacing.xs, fontSize: fontSize.lg },
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
  name: { fontSize: fontSize.md, fontWeight: '500' },
  desc: { marginTop: spacing.xs, fontSize: fontSize.sm, lineHeight: 18 },
  price: { marginTop: spacing.xs, fontSize: fontSize.sm },
  count: { marginTop: spacing.xs, fontSize: fontSize.xs },
  buy: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
  },
  buyText: { fontSize: fontSize.sm },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  emptyText: { fontSize: fontSize.sm, textAlign: 'center', lineHeight: 20 },
});
