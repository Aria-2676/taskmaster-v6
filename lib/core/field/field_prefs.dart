import 'dart:convert';

import 'task_field.dart';

/// 用户对字段的偏好：**顺序 + 哪些关了 + 默认值覆盖**。
///
/// 只存"差异"，不存字段定义 —— 字段定义永远来自 [FieldCatalog]，
/// 这样主包加字段时，老用户的偏好 JSON 里没有这个 id 也不会出问题，
/// 新字段自动追加到末尾、按自己的默认开关生效。
class FieldPrefs {
  const FieldPrefs({
    required this.order,
    required this.hidden,
    required this.defaults,
  });

  /// 出厂偏好
  factory FieldPrefs.initial() => FieldPrefs(
        order: <String>[for (final f in FieldCatalog.all) f.id],
        hidden: Set<String>.of(FieldCatalog.defaultHidden),
        defaults: const <String, String>{},
      );

  /// 解析失败**不抛**：偏好坏了只是回到出厂设置，不该让编辑页打不开。
  ///
  /// 这是有意的取舍 —— 配置的容错等级要低于业务数据。
  factory FieldPrefs.decode(String? raw) {
    if (raw == null || raw.isEmpty) return FieldPrefs.initial();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return FieldPrefs.initial();
      final json = Map<String, Object?>.from(decoded);
      return FieldPrefs.initial()._merge(json);
    } catch (_) {
      return FieldPrefs.initial();
    }
  }

  /// 顺序。可能缺字段（主包新加的），也可能多出字段（主包删掉的）
  final List<String> order;

  /// 关闭的字段 id
  final Set<String> hidden;

  /// 默认值覆盖，只有枚举类字段会进来
  final Map<String, String> defaults;

  bool isHidden(String id) => hidden.contains(id);

  /// 某个字段此刻生效的默认值：用户覆盖优先，其次字段自带。
  String? defaultOf(TaskField field) => defaults[field.id] ?? field.defaultValue;

  /// 补全 + 排序：以 [catalog] 为准，[order] 里认识的排前面，
  /// 不认识的（主包删掉的）丢掉，缺的（主包新加的）按目录顺序补到末尾。
  List<TaskField> ordered(List<TaskField> catalog) {
    final byId = <String, TaskField>{for (final f in catalog) f.id: f};
    final result = <TaskField>[];
    final seen = <String>{};

    for (final id in order) {
      final field = byId[id];
      if (field == null || !seen.add(id)) continue;
      result.add(field);
    }
    for (final field in catalog) {
      if (seen.add(field.id)) result.add(field);
    }
    return result;
  }

  /// 编辑页实际要画的字段（按顺序，去掉关掉的）
  List<TaskField> enabled(List<TaskField> catalog) =>
      ordered(catalog).where((f) => !hidden.contains(f.id)).toList();

  /// 被关掉、但这次编辑里有值的字段 —— 编辑页要提示"还有内容被藏着"，
  /// 否则用户会以为数据没了。
  List<TaskField> hiddenWithValue(
    List<TaskField> catalog,
    bool Function(TaskField field) hasValue,
  ) =>
      ordered(catalog)
          .where((f) => hidden.contains(f.id) && hasValue(f))
          .toList();

  FieldPrefs copyWith({
    List<String>? order,
    Set<String>? hidden,
    Map<String, String>? defaults,
  }) =>
      FieldPrefs(
        order: order ?? this.order,
        hidden: hidden ?? this.hidden,
        defaults: defaults ?? this.defaults,
      );

  FieldPrefs withHidden(String id, bool value) {
    final next = Set<String>.of(hidden);
    if (value) {
      next.remove(id);
    } else {
      next.add(id);
    }
    return copyWith(hidden: next);
  }

  FieldPrefs withDefault(String id, String? value) {
    final next = Map<String, String>.of(defaults);
    if (value == null) {
      next.remove(id);
    } else {
      next[id] = value;
    }
    return copyWith(defaults: next);
  }

  /// 拖拽换位。索引是"可见列表"里的索引，但写回去要落到完整 order 上。
  FieldPrefs reorder(int oldIndex, int newIndex, List<TaskField> catalog) {
    final list = ordered(catalog);
    if (oldIndex < 0 || oldIndex >= list.length) return this;
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target < 0 || target >= list.length || target == oldIndex) return this;

    final moved = list.removeAt(oldIndex);
    list.insert(target, moved);
    return copyWith(order: <String>[for (final f in list) f.id]);
  }

  String encode() => jsonEncode(<String, Object?>{
        'order': order,
        'hidden': hidden.toList()..sort(),
        'defaults': defaults,
      });

  FieldPrefs _merge(Map<String, Object?> json) {
    final rawOrder = json['order'];
    final rawHidden = json['hidden'];
    final rawDefaults = json['defaults'];

    final order = rawOrder is List
        ? <String>[
            for (final item in rawOrder)
              if (item is String && FieldCatalog.byId(item) != null) item,
          ]
        : this.order;

    // 锁定字段不允许被关：就算 JSON 被手改过也不能把关不掉的东西关掉
    final hidden = rawHidden is List
        ? <String>{
            for (final item in rawHidden)
              if (item is String && (FieldCatalog.byId(item)?.locked == false)) item,
          }
        : this.hidden;

    final defaults = <String, String>{};
    if (rawDefaults is Map) {
      for (final entry in rawDefaults.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) continue;
        final field = FieldCatalog.byId(key);
        // 只收枚举字段，且值必须真的在这个字段的档位里 —— 否则默认值会变成
        // 一个 UI 画不出来的幽灵值，界面上表现为"默认值设置没生效"
        if (field == null || !field.hasOptions) continue;
        if (!field.options.any((o) => o.value == value)) continue;
        defaults[key] = value;
      }
    }

    return FieldPrefs(order: order, hidden: hidden, defaults: defaults);
  }
}
