// v6 扩展位骨架 —— 插槽（区域级扩展）。
//
// 这是骨架，不是实现：v5 现有代码**不使用**本文件，主包重写时才接线。
// 约定见 docs/plugin-contract.md §4.1 与 .trae/rules/rule-8（插件边界）：
//   1. 插件**只提供数据**，不提供样式（字体/圆角/间距/颜色由主包决定）
//   2. 同一插槽有多个提供者时，按注册顺序取第一个"有效"的
//   3. 提供者抛异常、返回 null、或返回的值类型与插槽不符 → 跳过，主包用默认实现
//   4. 任何情况下不向 UI 抛异常

/// 插槽 id 白名单。新增一个必须同步 `docs/plugin-contract.md` §4.1。
enum SlotId {
  /// 顶栏日期显示格式（默认「10月22日 周四」）
  headerDate('slot.headerDate'),

  /// 货币徽章：数字与点击目标
  currencyBadge('slot.currencyBadge'),

  /// 日历条上的日期标记
  calendarMarks('slot.calendarMarks'),

  /// 任务卡片上的附加信息行
  taskCardExtra('slot.taskCardExtra');

  const SlotId(this.id);

  final String id;
}

/// 插槽值基类。**每个插槽只有唯一对应的子类型**，类型不符即视为无效。
sealed class SlotValue {
  const SlotValue();
}

class HeaderDateValue extends SlotValue {
  const HeaderDateValue(this.text);

  /// 纯文本，不含样式
  final String text;
}

class CurrencyBadgeValue extends SlotValue {
  const CurrencyBadgeValue({required this.value, this.route});

  final int value;

  /// 点击后跳转的路由名；null 表示不可点击
  final String? route;
}

class CalendarMarksValue extends SlotValue {
  const CalendarMarksValue(this.marks);

  /// key 为当天零点（本地时区），value 为标记类型，主包负责解释与绘制
  final Map<DateTime, String> marks;
}

class TaskCardExtraValue extends SlotValue {
  const TaskCardExtraValue({required this.taskId, required this.text});

  final int taskId;
  final String text;
}

/// 插槽提供者。v6 中由 WebView 侧经 bridge 返回数据后包装成此接口。
abstract class SlotProvider {
  /// 插件 id，用于卸载时按插件整体摘除
  String get pluginId;

  /// 本提供者要参与的插槽
  Set<SlotId> get slots;

  /// 返回 null 表示"本次不提供"，主包落到默认实现
  SlotValue? provide(SlotId slot, Map<String, Object?> context);
}

/// 插槽注册表。骨架阶段为进程内单例，无持久化。
class SlotRegistry {
  SlotRegistry._();

  static final SlotRegistry instance = SlotRegistry._();

  final Map<SlotId, List<SlotProvider>> _bySlot = <SlotId, List<SlotProvider>>{};

  void register(SlotProvider provider) {
    for (final slot in provider.slots) {
      (_bySlot[slot] ??= <SlotProvider>[]).add(provider);
    }
  }

  void unregister(String pluginId) {
    for (final list in _bySlot.values) {
      list.removeWhere((p) => p.pluginId == pluginId);
    }
  }

  /// 解析插槽值。**永不抛出**：异常、null、类型不符都返回 null，
  /// 由调用方落到主包默认实现。
  SlotValue? resolve(SlotId slot, {Map<String, Object?> context = const {}}) {
    final candidates = _bySlot[slot];
    if (candidates == null || candidates.isEmpty) return null;

    for (final provider in List<SlotProvider>.of(candidates)) {
      SlotValue? value;
      try {
        value = provider.provide(slot, context);
      } catch (_) {
        continue;
      }
      if (value == null) continue;
      if (!_accepts(slot, value)) continue;
      return value;
    }
    return null;
  }

  List<String> get providerIds {
    final ids = <String>{};
    for (final list in _bySlot.values) {
      for (final p in list) {
        ids.add(p.pluginId);
      }
    }
    return ids.toList()..sort();
  }

  void clear() => _bySlot.clear();

  static bool _accepts(SlotId slot, SlotValue value) => switch (slot) {
    SlotId.headerDate => value is HeaderDateValue,
    SlotId.currencyBadge => value is CurrencyBadgeValue,
    SlotId.calendarMarks => value is CalendarMarksValue,
    SlotId.taskCardExtra => value is TaskCardExtraValue,
  };
}
