/**
 * 积分明细的展示口径（纯函数，无 DB / 无 RN 依赖）
 *
 * 对应 docs/migration/spec-points-shop.md A.3 / A.8 与
 * docs/migration/schema-v3.md §2.4。
 *
 * 为什么单独抽一层：明细页的「文案 / 图标 / 正负号 / 排序」是**纯展示决策**，
 * 混在仓储或 UI 里就会出现两处各写一份、然后慢慢走样。这里定一份，
 * 用 `node --experimental-strip-types` 就能回归，不依赖设备。
 *
 * ⚠️ 与 `repo/types.ts` 的 `PointsType` **同名但取值不同**：
 * `types.ts` 只有 5 种（照抄了 schema-v3 §3.3，而那份文档本身是错的，见
 * spec G1），真实有 **7 种**——多出 `shop_purchase` / `scratch_cost`。
 * 本文件导出的 `PointsRecordType` 才是权威取值，仓储层请用本文件的。
 */

/* ── 七种流水类型 ─────────────────────────────────────────────────────── */

/**
 * `points_records.type` 的**全部 7 种**取值。
 *
 * 取值来源以代码为准（spec G1）：
 * - `schema-v3.md §3.3` 只列了 5 种，漏掉 `shop_purchase` / `scratch_cost`
 *   这两种**商城与刮刮乐的主流水类型**——该文档待修正。
 */
export type PointsRecordType =
  | 'task_complete'
  | 'task_uncomplete'
  | 'overdue_deduct'
  | 'shop_purchase'
  | 'scratch_cost'
  | 'scratch_win'
  | 'scratch_refund';

/** 全部取值的数组形式，供测试遍历（不要在别处硬编码一份）。 */
export const POINTS_RECORD_TYPES: readonly PointsRecordType[] = [
  'task_complete',
  'task_uncomplete',
  'overdue_deduct',
  'shop_purchase',
  'scratch_cost',
  'scratch_win',
  'scratch_refund',
];

/** 未知类型的兜底文案。用于库里有本次版本没识别的 type（升级过的老库）。 */
export const UNKNOWN_TYPE_LABEL = '积分变动';

/* ── 图标 / 文案 / 符号 ───────────────────────────────────────────────── */

/**
 * 展示口径里的符号：1 = 收入（通常为正），0 = 中性，-1 = 支出。
 * **注意**：真正决定显示为「收入」还是「支出」的是 `points` 的**实际值**
 * （见 `isIncome`），这里的 `sign` 只是每种类型的**预期**符号，
 * 用于自检与文档，不参与渲染决策。
 */
export type AmountSign = 1 | 0 | -1;

/** 单种类型的展示元数据。 */
export interface PointsTypeMeta {
  /** 中文文案（短标签，用于分类展示）。 */
  readonly label: string;
  /**
   * 图标名。**沿用 Flutter 侧的 Material 图标名**（`Icons.xxx` 的名字），
   * RN 侧只需建一张「同名 → 组件」的映射表即可一一对应，不要另起名字，
   * 否则迁移前后对不上号。
   */
  readonly icon: string;
  /** 该类型预期的符号。渲染仍以 `points` 实际值为准。 */
  readonly sign: AmountSign;
}

/**
 * 七种类型的展示元数据。
 *
 * 图标 / 颜色对应 Flutter 侧**死代码**页 `points_record_page.dart:127` 的映射表
 * （该页无路由、无人引用，但映射表本身是全的，可直接复用）。
 * 生效版页面只按正负分 `add_circle` / `remove_circle`；这里提供差异化图标，
 * 属于**展示增强**，不改变任何数据行为。
 */
export const POINTS_TYPE_META: Readonly<Record<PointsRecordType, PointsTypeMeta>> = {
  task_complete: { label: '完成任务', icon: 'check_circle', sign: 1 },
  task_uncomplete: { label: '取消完成', icon: 'cancel', sign: -1 },
  overdue_deduct: { label: '逾期扣分', icon: 'warning', sign: -1 },
  shop_purchase: { label: '商城兑换', icon: 'shopping_bag', sign: -1 },
  scratch_cost: { label: '购买刮刮卡', icon: 'casino', sign: -1 },
  scratch_win: { label: '刮奖中奖', icon: 'celebration', sign: 1 },
  scratch_refund: { label: '刮奖退款', icon: 'refresh', sign: 1 },
};

/** 未知类型的兜底元数据（对应 Dart 侧的 `default` 分支 `swap_horiz`）。 */
export const UNKNOWN_TYPE_META: PointsTypeMeta = {
  label: UNKNOWN_TYPE_LABEL,
  icon: 'swap_horiz',
  sign: 0,
};

/**
 * 取展示元数据。传入库里读到的**原始字符串**（不收窄成 `PointsRecordType`），
 * 这样老库里出现的未知 type 不会让整页崩掉，而是走兜底。
 */
export function typeMeta(type: string): PointsTypeMeta {
  return POINTS_TYPE_META[type as PointsRecordType] ?? UNKNOWN_TYPE_META;
}

/** 该 type 的中文文案。 */
export function typeLabel(type: string): string {
  return typeMeta(type).label;
}

/** 该 type 的图标名。 */
export function typeIcon(type: string): string {
  return typeMeta(type).icon;
}

/* ── 金额正负 ─────────────────────────────────────────────────────────── */

/**
 * 是否是收入。
 *
 * 判定依据是 `points` 的**实际值**：`points > 0` 即收入（spec A.8）。
 * 流水里的 `points` **永远带符号**，明细页直接靠它判断收支，
 * 不做绝对值处理、也不看 `type`。
 *
 * 副作用（照搬）：`points === 0` 的流水会走进「支出」分支，显示为红色的 `0`。
 * 这是 Flutter 版的原样行为，正常路径下也不会产生 0 分流水。
 */
export function isIncome(points: number): boolean {
  return points > 0;
}

/** 显示用的符号前缀：收入 `'+'`、其余 `''`（负号本身就在数值里）。 */
export function signPrefix(points: number): string {
  return isIncome(points) ? '+' : '';
}

/**
 * 明细页显示的金额字符串。
 *
 * - `10`  → `'+10'`
 * - `-10` → `'-10'`
 * - `0`   → `'0'`
 *
 * 正数补 `+`、负数由数值自带负号，因此**直接输出 `points.toString()` 即可**，
 * 绝不能对负数再取绝对值（那会把支出显示成收入）。
 */
export function formatAmount(points: number): string {
  if (isIncome(points)) return `+${points}`;
  return String(points);
}

/* ── 明细列表的排序与条数 ─────────────────────────────────────────────── */

/** 明细页最多取多少条。照搬 `getPointsRecords(limit: 50)`（spec A.8）。 */
export const POINTS_RECORD_LIMIT = 50;

/**
 * 明细列表的排序规则：**`created_at` 倒序**（spec A.8 的真实口径）。
 *
 * ⚠️ 关于「七种 type 的排序权重」：**spec 里并不存在这种权重。**
 * A.8 明确写的是 `SELECT * FROM points_records ORDER BY created_at DESC LIMIT 50`
 * —— 纯按时间倒序，**不按 type 分组、不加权**；并且**没有分页、没有「加载更多」、
 * 没有汇总统计**。已就此向负责人报出，不自行发明一套 type 权重。
 *
 * 附加说明：本函数在 `created_at` 相同时用 `id` 倒序兜底，保证排序**全序且稳定**。
 * 这不改变 Flutter 版的行为（同毫秒的两条流水原本顺序不定），
 * 只是把「不定」收敛成「确定的倒序」，避免列表重渲染时行序跳动。
 * 注意排序依据**只有** `created_at`，与结算幂等用的 `ORDER BY id DESC`（spec F9）
 * 是两回事，不要混用。
 */
export function comparePointsRecords(
  a: { created_at: string; id: number },
  b: { created_at: string; id: number },
): number {
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? 1 : -1;
  return b.id - a.id;
}

/* ── 标签颜色 ─────────────────────────────────────────────────────────── */

/** 新建标签时的默认色（`tags.color` 的数据库默认值，也是色板里的第一格）。 */
export const DEFAULT_TAG_COLOR = '#2196F3';

/**
 * 颜色解析失败时的兜底色。
 *
 * 对应 Flutter 的 `Colors.blue`，注意它是 **Material Blue 500 = 0xFF2196F3**，
 * 与 `DEFAULT_TAG_COLOR` 恰好同值——所以「兜底成蓝色」和「默认蓝色」看起来一样。
 */
export const FALLBACK_TAG_COLOR_ARGB = 0xff2196f3;

/** 16 色可选色板（照搬 `tag_management_page.dart:182` 的硬编码值）。 */
export const TAG_COLOR_PALETTE: readonly string[] = [
  '#F44336',
  '#E91E63',
  '#9C27B0',
  '#673AB7',
  '#3F51B5',
  '#2196F3',
  '#00BCD4',
  '#009688',
  '#4CAF50',
  '#8BC34A',
  '#CDDC39',
  '#FFC107',
  '#FF9800',
  '#FF5722',
  '#795548',
  '#9E9E9E',
];

/** 合法的 6 位 `#RRGGBB`。 */
const SIX_DIGIT_HEX = /^#?[0-9a-fA-F]{6}$/;

/**
 * 解析 `tags.color`（**`'#RRGGBB'` 字符串**）为带 alpha 的 ARGB 整数。
 *
 * `tags.color` 与 `shop_items.color_value` 是**两种不同的类型**：
 * 前者是字符串、后者是 ARGB 整数，**两者不能共用解析函数**（spec B.1 / F16）。
 * 本函数只服务 `tags.color`。
 *
 * 解析规则照搬 `tag_model.dart:67`：把 `FF` 拼在前面当 alpha，即
 * `#2196F3` → `0xFF2196F3`。所以**库里存的应当永远是 6 位、不带 alpha**。
 *
 * ⚠️ **已知现象：8 位色值会静默降级为兜底蓝色。**
 * 若某行存了 8 位 `#AARRGGBB`，拼上 `FF` 后是 10 位十六进制，超出 ARGB 的
 * 32 位表示范围，因此这里**直接判为非法并返回兜底蓝色**，不抛错、不提示——
 * 用户只会看到标签变成蓝色，看不出「本来是什么色」。
 * （补一句：spec C.2 把这个降级的**原因**写成「`int.parse` 抛异常」并不准确——
 * 10 位十六进制对 `parseInt` 来说是合法数字，能解析成功，只是结果溢出 32 位。
 * 真正必须拦截的理由是 **ARGB 只有 8 位**，超长输入没有正确表示。）
 * 另外 `int.parse` 只在含**非十六进制字符**时才会真的抛异常，那种情况同样兜底。
 */
export function parseTagColorArgb(color: string): number {
  if (!SIX_DIGIT_HEX.test(color)) return FALLBACK_TAG_COLOR_ARGB;
  return parseInt(`FF${color.replace('#', '')}`, 16);
}

/* ── 仓库按名分组 ─────────────────────────────────────────────────────── */

/** 仓库页的一个分组：同名商品合并为一组。 */
export interface WarehouseGroup<T> {
  /** 分组键——**快照里的商品名字符串**，不是 `shop_item_id`。 */
  readonly name: string;
  /** 组内条目，保持传入顺序（= `purchased_at` 倒序）。 */
  readonly items: readonly T[];
  /** 组内条数。 */
  readonly count: number;
  /** 最新的一条——**卡片上的图标 / 颜色 / 描述 / 价格取的是这一条**。 */
  readonly latest: T;
  /** 最旧的一条——**「使用」按钮删掉的是这一条**（与上面不是同一条！）。 */
  readonly oldest: T;
}

/**
 * 按**快照 name** 把已购记录分组（照搬 `warehouse_page.dart:28`）。
 *
 * 分组键是字符串而非 id，所以这两个怪现象是**既定行为**（spec B.5 / H6，照搬）：
 * - 同一个商品改过名 → **分裂成两组**（旧名一组、新名一组），哪怕 `shop_item_id` 相同；
 * - 两个不同 id 但重名（`name` 无 UNIQUE 约束）→ **合并成一组**。
 *
 * 组内显示的图标 / 颜色 / 描述 / 价格一律取 `latest`（最新那条的快照值），
 * 所以同一组内若期间改过价，会显示不同价格但只展示一个——照搬。
 *
 * 组顺序 = 某个 name **首次出现**的顺序；传入列表已按 `purchased_at DESC` 排好，
 * 所以组顺序即「按最近兑换时间倒序」，**不是**按数量或字典序。
 *
 * @param items 已按 `purchased_at DESC` 排好的已购记录（**顺序敏感，不要先排序**）
 */
export function groupPurchasedByName<T extends { name: string }>(
  items: readonly T[],
): WarehouseGroup<T>[] {
  const order: string[] = [];
  const buckets = new Map<string, T[]>();

  for (const item of items) {
    const bucket = buckets.get(item.name);
    if (bucket === undefined) {
      // 首次出现该名字 → 决定这一组在列表中的位置
      order.push(item.name);
      buckets.set(item.name, [item]);
    } else {
      bucket.push(item);
    }
  }

  return order.map(name => {
    const groupItems = buckets.get(name) ?? [];
    return {
      name,
      items: groupItems,
      count: groupItems.length,
      // 调用方保证按 purchased_at DESC 传入，故 [0] 最新、末条最旧
      latest: groupItems[0],
      oldest: groupItems[groupItems.length - 1],
    };
  });
}

/**
 * 「使用」按钮应当删除的那一条：**`items.last`（最旧）**。
 *
 * 卡片上显示的却是 `items.first`（最新）。**删除的记录和显示的记录不是同一条**，
 * 这是有意为之（先消耗囤积，oldest-first），极易看错（spec B.5 / F22）。
 */
export function pickOldestForUse<T extends { name: string }>(group: WarehouseGroup<T>): T {
  return group.oldest;
}