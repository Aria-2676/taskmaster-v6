/**
 * 商城状态。
 *
 * ── 三条不能搞反的既有语义 ────────────────────────────────────────────
 *
 * 1. **「使用」删的是 `oldest`，卡片显示的是 `latest`**（spec B.5 / F22）。
 *    仓库卡片上的图标 / 价格取自 `group.latest`，点「使用」删掉的却是
 *    `group.oldest`（先消耗囤积）。`consume()` 拿到的是卡片上的那个 id，
 *    由本 store 负责换成最旧的那条——界面不要自己去猜。
 * 2. **兑换的三步（扣分 / 写流水 / 写已购快照）在 `shopRepo` 的一个事务里**，
 *    本 store 不做补偿、不重试。余额不足时是**零写入**，不是「扣了分没拿到商品」。
 * 3. **兑换的 `purchased_items` 是快照**：商品改名 / 改价后历史记录不跟随。
 *    所以刷新是整表重读，不做任何关联纠正（schema-v3 §5 第 7 条）。
 *
 * ⚠️ 本 store 不提供「新增 / 删除商品」：商品**无编辑入口**（spec B.4 / F23），
 * 且删商品会让 `purchased_items.shop_item_id` 变成悬空引用。
 */

import { create } from 'zustand';
import * as shopRepo from '../repo/shopRepo';
import { pickOldestForUse } from '../core/pointsRules';
import { usePointsStore } from './pointsStore';
import { fail, ok } from './ops';
import type { OpResult, ShopStoreState } from './contracts';

export const useShopStore = create<ShopStoreState>((set, get) => ({
  items: [],
  purchased: [],
  groups: [],
  lastPurchaseResult: null,

  /** 同步重读商品 / 已购 / 分组。三个读操作都是同步的。 */
  refresh: () => {
    set({
      items: shopRepo.getAllShopItems(),
      purchased: shopRepo.getAllPurchasedItems(),
      groups: shopRepo.getWarehouseGroups(),
    });
  },

  purchase: async (shopItemId: number): Promise<OpResult> => {
    // ⚠️ `purchaseShopItem` 收的是**整个商品对象**而不是 id（它内部会再查一次
    // 存在性），价格来源只有 `item.price` 一个，杜绝「扣 A 分、记 B 分」。
    const item = shopRepo.getShopItem(shopItemId);
    if (!item) {
      set({ lastPurchaseResult: { ok: false, reason: 'item_not_found' } });
      return { ok: false, message: '商品不存在' };
    }

    try {
      const result = await shopRepo.purchaseShopItem({
        id: item.id,
        name: item.name,
        description: item.description,
        price: item.price,
        icon_name: item.icon_name,
        color_value: item.color_value,
      });
      set({ lastPurchaseResult: result });

      if (result.ok) {
        // 兑换会扣分 → 余额与流水都变了，顺手刷掉，免得界面上看到旧余额。
        usePointsStore.getState().refresh();
        get().refresh();
      }
      return { ok: result.ok, message: shopRepo.purchaseResultMessage(result) };
    } catch (e) {
      set({ lastPurchaseResult: null });
      return fail(e);
    }
  },

  /**
   * 用掉一件已购商品。
   *
   * @param purchasedItemId 卡片上那条（`latest`）的 id；本函数会换成
   *                        同组内**最旧**的那条再删。
   *
   * ⚠️ `deletePurchasedItem` 声明成 `export function` 却返回 Promise，
   * 漏掉 await 时 tsc 完全不报错——必须 await。
   *
   * ⚠️ 不退积分、不留痕：只 DELETE，既不写 `points_records` 也不改
   * `user_points`，所以「余额 == SUM(流水)」的不变量不受影响（spec B.5）。
   */
  consume: async (purchasedItemId: number): Promise<OpResult> => {
    // 现读分组而不是用 `get().groups` 缓存：缓存可能已被别的写入弄旧，
    // 而「哪条最旧」必须是此刻的真实值。
    const group = shopRepo
      .getWarehouseGroups()
      .find(g => g.items.some(i => i.id === purchasedItemId));
    if (!group) {
      return { ok: false, message: '这件商品已不在仓库中' };
    }

    try {
      await shopRepo.deletePurchasedItem(pickOldestForUse(group).id);
      get().refresh();
      return ok();
    } catch (e) {
      return fail(e);
    }
  },
}));
