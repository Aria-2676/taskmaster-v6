/**
 * 商城仓储：商品列表 / 播种、兑换（同事务三步）、兑换记录（按快照 name 分组）。
 *
 * 对应 Flutter 侧 `database_shop_mixin.dart` + `database_purchase_mixin.dart`
 * + `shop_provider.dart`，规格见 docs/migration/spec-points-shop.md B 章。
 *
 * ── 关键约束 ───────────────────────────────────────────────────────────
 *
 * - **兑换的「扣分 / 写流水 / 写 `purchased_items` 快照」必须同一事务**，
 *   任一步失败整体回滚（spec B.3 / F5）。这正是「不能扣了分却拿不到商品」的防线。
 * - **商品无库存字段**、**无编辑入口**（`updateShopItem` 无任何 UI 调用方，
 *   spec B.4 / F23）。想要就重复买。
 * - **`shop_purchase` 的 `related_id` 指向 `shop_items.id`**，不是
 *   `purchased_items.id`（`purchased_items.id` 在写流水时尚未生成，spec F19）。
 * - **`purchased_items` 是快照**：改名 / 改价后历史记录不跟随变化，
 *   迁移与查询都**不要**做关联纠正（schema-v3 §5 第 7 条）。
 * - **表空时自动播种**：用户删光全部商品后重启，8 个默认商品会重新长出来
 *   （spec B.1.2 / F15）。这是既定行为，照搬。
 */

import { queryOne, queryAll, writeBatch, nowLocalIso } from './base';
import { exec, execInsert, runTransaction, ensureUserPointsRow, type Tx } from './tx';
import { InsufficientPointsError } from './tx';
import { insertRecord, getBalance } from './pointsRepo';
import type { ShopItemRow, PurchasedItemRow } from './types';
import { groupPurchasedByName, type WarehouseGroup } from '../core/pointsRules';

/** 建商品时的默认 ARGB 色（`0xFF9C27B0`，与 DDL 默认值一致）。 */
export const DEFAULT_SHOP_COLOR = 0xff9c27b0;

/** 建商品时的默认图标名（与 DDL 默认值一致）。 */
export const DEFAULT_SHOP_ICON = 'shopping_bag';

/**
 * 可选图标名（**28 个**，照搬 `shop_model.dart:25` 的硬编码映射表）。
 *
 * ⚠️ 这里存的是**字符串枚举**，RN 侧需自建「同名 → 图标组件」的映射表。
 * 未命中的名字**静默降级为购物袋、不报错**（spec B.1.1），
 * 所以新增图标名时务必同步改这张表，否则 UI 上会全部显示成购物袋。
 */
export const SHOP_ICON_NAMES: readonly string[] = [
  'shopping_bag',
  'card_giftcard',
  'star',
  'favorite',
  'emoji_events',
  'local_cafe',
  'restaurant',
  'cake',
  'icecream',
  'sports_esports',
  'movie',
  'music_note',
  'book',
  'sports',
  'fitness_center',
  'flight',
  'beach_access',
  'pets',
  'shopping_cart',
  'phone_iphone',
  'laptop',
  'headphones',
  'watch',
  'camera',
  'lightbulb',
  'eco',
  'local_florist',
  'spa',
];

/** 未命中时的兜底图标名。 */
export const FALLBACK_SHOP_ICON = 'shopping_bag';

/** 取图标名，未命中则兜底为购物袋（**静默降级，不报错**）。 */
export function resolveShopIcon(iconName: string): string {
  return SHOP_ICON_NAMES.includes(iconName) ? iconName : FALLBACK_SHOP_ICON;
}

/** 新增商品的入参。`id` / `created_at` 由仓储生成。 */
export interface NewShopItem {
  name: string;
  /** `NOT NULL`，写入时兜底为空串（spec B.2）。 */
  description?: string | null;
  /**
   * 积分数。
   * ⚠️ **无下限约束**，表单也不校验正数——照搬。负价格会导致「购买时反而加积分」，
   * 这是已知缺陷；修它属行为变更，需产品决策。
   */
  price: number;
  iconName?: string | null;
  /** ARGB 整数。 */
  colorValue?: number | null;
}

/** 默认商品（首次启动播种，8 个）——照搬 `shop_provider.dart:42` 的真实数据。 */
const DEFAULT_SHOP_ITEMS: readonly NewShopItem[] = [
  { name: '休息15分钟', description: '兑换后可以休息15分钟，放松身心', price: 50, iconName: 'local_cafe', colorValue: 0xff795548 },
  { name: '看一集动漫', description: '奖励自己看一集喜欢的动漫', price: 100, iconName: 'movie', colorValue: 0xffe91e63 },
  { name: '吃一块蛋糕', description: '兑换一块美味的蛋糕奖励自己', price: 80, iconName: 'cake', colorValue: 0xffff9800 },
  { name: '玩游戏30分钟', description: '兑换30分钟游戏时间', price: 120, iconName: 'sports_esports', colorValue: 0xff9c27b0 },
  { name: '买一本书', description: '兑换购买一本心仪的书籍', price: 200, iconName: 'book', colorValue: 0xff4caf50 },
  { name: '周末旅行', description: '兑换一次周末短途旅行', price: 500, iconName: 'flight', colorValue: 0xff2196f3 },
  { name: '买新装备', description: '兑换购买新的电子设备或配件', price: 300, iconName: 'laptop', colorValue: 0xff607d8b },
  { name: 'SPA放松', description: '兑换一次SPA按摩放松', price: 400, iconName: 'spa', colorValue: 0xff00bcd4 },
];

/* ── 商品 ─────────────────────────────────────────────────────────────── */

/** 全部商品，`created_at` 倒序（照搬 `getAllShopItems` 的 `orderBy`）。 */
export function getAllShopItems(): ShopItemRow[] {
  return queryAll<ShopItemRow>(
    `SELECT id, name, description, price, created_at, icon_name, color_value
       FROM shop_items
      ORDER BY created_at DESC`,
    [],
    '读取商品列表',
  );
}

/** 按 id 读单个商品。 */
export function getShopItem(id: number): ShopItemRow | undefined {
  return queryOne<ShopItemRow>(
    `SELECT id, name, description, price, created_at, icon_name, color_value
       FROM shop_items
      WHERE id = ? LIMIT 1`,
    [id],
    '读取商品',
  );
}

/**
 * 新增商品，返回新 id。
 *
 * 用 `runTransaction` + `execInsert` 取 `insertId`，而不是
 * `writeBatch` 之后再查 `last_insert_rowid()`——后者是**连接级全局状态**，
 * 并发插入时会拿到别的语句的 id。`writeBatch`（`executeBatch`）只返回整批
 * 总 `rowsAffected`、不返回逐条 `insertId`，所以这里必须走事务路径。
 */
export async function createShopItem(item: NewShopItem): Promise<number> {
  // description 是 NOT NULL，绕过 UI 直接构造时可能传 null —— 兜底空串。
  const description = item.description ?? '';
  const iconName = item.iconName ?? DEFAULT_SHOP_ICON;
  const colorValue = item.colorValue ?? DEFAULT_SHOP_COLOR;
  return runTransaction(
    tx =>
      execInsert(
        tx,
        `INSERT INTO shop_items (name, description, price, created_at, icon_name, color_value)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [item.name, description, item.price, nowLocalIso(), iconName, colorValue],
      ),
    '新增商品',
  );
}

/**
 * 读取某商品已兑换次数。
 *
 * Flutter 侧是 `purchasedItems.where(...).length`——**每次调用全表线性扫描**。
 * 这里用 SQL `COUNT`，结果必须一致（spec B.4）。
 */
export function getPurchasedCount(shopItemId: number): number {
  const row = queryOne<{ c: number }>(
    'SELECT COUNT(*) AS c FROM purchased_items WHERE shop_item_id = ?',
    [shopItemId],
    '统计兑换次数',
  );
  return row?.c ?? 0;
}

/**
 * 删除商品（**不进回收站**，直接物理删除）。
 *
 * ⚠️ 删除后 `purchased_items.shop_item_id` 变成悬空引用，但**无外键约束**，
 * 所以不会失败、不会级联；因为展示全靠快照列，**UI 完全无感知**（spec B.2）。
 *
 * ⚠️ **不要**在这里「顺手」清理或改名重名的商品：刮刮乐的奖品池是靠
 * `shop_items.name` 字符串匹配来兑换奖品的（`prize_type='goods'`），
 * 改名会让已配好的奖品池**匹配不到而抛错**（spec B.6 / G9）。
 */
export function deleteShopItem(id: number): Promise<void> {
  return writeBatch([['DELETE FROM shop_items WHERE id = ?', [id]]], '删除商品');
}

/**
 * 表空时播种 8 个默认商品。
 *
 * ⚠️ 判定条件是「**`shop_items` 表为空**」，不是「用户没建过商品」。
 * 用户手动删光所有商品后重启，这 8 个商品会**重新长出来**（spec B.1.2 / F15）。
 * 必须复刻，否则用户删商品后重启会困惑于商品「复活」。
 *
 * @returns 实际插入的条数；表非空时返回 0
 */
export async function seedDefaultShopItemsIfEmpty(): Promise<number> {
  const row = queryOne<{ c: number }>(
    'SELECT COUNT(*) AS c FROM shop_items',
    [],
    '检查商品表',
  );
  if ((row?.c ?? 0) > 0) return 0;

  const now = nowLocalIso();
  await writeBatch(
    DEFAULT_SHOP_ITEMS.map(item => [
      `INSERT INTO shop_items (name, description, price, created_at, icon_name, color_value)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        item.name,
        item.description ?? '',
        item.price,
        now,
        item.iconName ?? DEFAULT_SHOP_ICON,
        item.colorValue ?? DEFAULT_SHOP_COLOR,
      ],
    ]),
    '初始化默认商品',
  );
  return DEFAULT_SHOP_ITEMS.length;
}

/* ── 兑换（事务三步） ─────────────────────────────────────────────────── */

/** 兑换结果。用可辨识的联合类型，避免调用方靠 `false` 猜原因。 */
export type PurchaseResult =
  | { ok: true; purchasedItemId: number; remainingPoints: number }
  | { ok: false; reason: 'insufficient_points' | 'item_not_found' | 'invalid_item' };

/**
 * 原子兑换商品：**扣分 + 写积分流水 + 写已购快照，三步同一事务**。
 *
 * 照搬 `purchaseShopItem`（spec B.3）：
 * 1. 确保 `user_points` 行存在（在事务外做，见 `tx.ts` 纪律第 3 条）；
 * 2. `UPDATE ... WHERE id = 1 AND points >= price`——**余额校验下推到 SQL**，
 *    命中 0 行即余额不足，抛 `InsufficientPointsError` 让**整笔回滚、零写入**；
 * 3. 写 `points_records`（`related_id` = **商品 id**，不是 `purchased_items.id`）；
 * 4. 写 `purchased_items` 快照（`price` 与扣分用**同一个变量**，避免不一致）。
 *
 * ⚠️ Flutter 的签名是 `purchaseShopItem({required item, required price})`，
 * 步骤 D 用的却是 `item.price` 而非 `price` 参数。当前两者一致，
 * 但那样写一旦调用方传了不同的 `price` 就会「扣 A 分、记 B 分」。
 * 这里**只接受一个价格来源**（`item.price`），从签名上消除这个风险。
 *
 * ⚠️ 余额不足时**零写入**：不会出现「流水写了但商品没进仓库」（spec B.4）。
 */
export async function purchaseShopItem(item: {
  id: number | null;
  name: string;
  description?: string | null;
  price: number;
  icon_name?: string | null;
  color_value?: number | null;
}): Promise<PurchaseResult> {
  if (item.id === null || item.id === undefined) return { ok: false, reason: 'invalid_item' };

  // 与 Flutter 一致的快速校验：商品必须真实存在（可能被并发删掉）。
  const existing = getShopItem(item.id);
  if (!existing) return { ok: false, reason: 'item_not_found' };

  ensureUserPointsRow();
  const price = existing.price;
  const now = nowLocalIso();

  try {
    const purchasedItemId = await runTransaction(
      async (tx: Tx) => {
        // 步骤 B：原子扣分，余额校验下推到 WHERE
        const affected = await exec(
          tx,
          'UPDATE user_points SET points = points - ?, updated_at = ? WHERE id = ? AND points >= ?',
          [price, now, 1, price],
        );
        if (affected === 0) throw new InsufficientPointsError(price);

        // 步骤 C：写积分流水（related_id 指向 shop_items.id）
        await insertRecord(tx, {
          points: -price,
          type: 'shop_purchase',
          description: `购买商品: ${existing.name}`,
          relatedId: existing.id,
        });

        // 步骤 D：写已购快照（price 与步骤 B 用同一个变量）
        return execInsert(
          tx,
          `INSERT INTO purchased_items
             (shop_item_id, name, description, price, purchased_at, icon_name, color_value)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
          [
            existing.id,
            existing.name,
            existing.description ?? '',
            price,
            now,
            existing.icon_name ?? DEFAULT_SHOP_ICON,
            existing.color_value ?? DEFAULT_SHOP_COLOR,
          ],
        );
      },
      '兑换商品',
    );
    return { ok: true, purchasedItemId, remainingPoints: getBalance() };
  } catch (e) {
    if (e instanceof InsufficientPointsError) {
      return { ok: false, reason: 'insufficient_points' };
    }
    throw e;
  }
}

/** 余额不足时对外展示的文案（照搬 `shop_provider.dart` 的返回字符串）。 */
export const INSUFFICIENT_POINTS_MESSAGE = '积分不足，无法兑换';

/** 把兑换结果翻译成 UI 可直接展示的文案；`null` 表示成功（照搬该 Provider 的约定）。 */
export function purchaseResultMessage(result: PurchaseResult): string | null {
  if (result.ok) return null;
  return INSUFFICIENT_POINTS_MESSAGE;
}

/* ── 兑换记录（仓库） ─────────────────────────────────────────────────── */

/** 全部已购记录，`purchased_at` 倒序（照搬 `getAllPurchasedItems`）。 */
export function getAllPurchasedItems(): PurchasedItemRow[] {
  return queryAll<PurchasedItemRow>(
    `SELECT id, shop_item_id, name, description, price, purchased_at, icon_name, color_value
       FROM purchased_items
      ORDER BY purchased_at DESC`,
    [],
    '读取兑换记录',
  );
}

/**
 * 仓库页的分组结果。
 *
 * ⚠️ **按快照 `name` 字符串分组，不是 `shop_item_id`**（spec B.5 / F21）。
 * 因此：商品改名 → **分裂成两组**；不同 id 但重名 → **合并成一组**。
 * 两个都是既定行为（spec H6 裁定照搬），不是 bug。
 */
export function getWarehouseGroups(): WarehouseGroup<PurchasedItemRow>[] {
  return groupPurchasedByName(getAllPurchasedItems());
}

/**
 * 「使用」商品：**物理删除** `purchased_items` 的一行。
 *
 * ⚠️ 三件事必须记住（spec B.5）：
 * 1. 「使用」按钮删的是 **`items.last`（最旧的那条）**，而卡片上显示的价格 / 描述 /
 *    图标来自 **`items.first`（最新）**——**删除的记录和显示的记录不是同一条**。
 *    这是有意为之（先消耗囤积，oldest-first），极易看错。取哪一条请用
 *    `core/pointsRules.ts` 的 `pickOldestForUse`。
 * 2. **不退还积分、不留痕**：只 `DELETE`，**不写** `points_records`、
 *    **不改** `user_points`。所以「余额 == SUM(流水)」的不变量不受影响。
 * 3. **不进回收站**（标签和商品都没有回收站）。
 */
export function deletePurchasedItem(id: number): Promise<void> {
  return writeBatch([['DELETE FROM purchased_items WHERE id = ?', [id]]], '使用商品');
}