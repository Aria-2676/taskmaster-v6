import 'package:flutter/foundation.dart';

import '../../core/field/field_prefs.dart';
import '../../core/field/task_field.dart';
import '../data/settings_repository.dart';

/// 字段偏好的状态。**只管配置，不碰任务数据**。
///
/// 编辑页从 [enabled] 取要画哪些字段，字段管理页从 [ordered] 取全部。
/// 两边读的是同一份偏好，所以"改完立刻生效"不需要任何额外通知。
class FieldStore extends ChangeNotifier {
  FieldStore(this._settings);

  final SettingsRepository _settings;

  FieldPrefs _prefs = FieldPrefs.initial();
  bool _loaded = false;

  FieldPrefs get prefs => _prefs;
  bool get loaded => _loaded;

  /// 全部字段，按用户顺序
  List<TaskField> get ordered => _prefs.ordered(FieldCatalog.all);

  /// 编辑页要画的字段
  List<TaskField> get enabled => _prefs.enabled(FieldCatalog.all);

  int get enabledCount => enabled.length;

  bool isHidden(String id) => _prefs.isHidden(id);

  /// 此刻生效的默认值（用户覆盖 > 字段自带 > null 表示不设）
  String? defaultOf(TaskField field) => _prefs.defaultOf(field);

  /// 用户是不是亲手改过这个字段的默认值。
  /// 编辑页靠它决定要不要标「默认」—— 没改过就不标，
  /// 否则优先级那种"永远有值"的字段会一直挂个牌子，纯噪音。
  bool hasDefaultOverride(String id) => _prefs.defaults.containsKey(id);

  Future<void> load() async {
    _prefs = FieldPrefs.decode(await _settings.get(SettingsKeys.fieldPrefs));
    _loaded = true;
    notifyListeners();
  }

  /// [visible] 为 true 表示打开这个字段。
  /// 锁定字段（标题/日期）传 false 会被静默忽略 —— 界面上本来就没有那个开关，
  /// 但代码路径上还是要挡住，免得哪天从别处调进来把任务弄成不可用。
  Future<void> setVisible(String id, bool visible) async {
    final field = FieldCatalog.byId(id);
    if (field == null) return;
    if (!visible && field.locked) return;

    final next = _prefs.withHidden(id, visible);
    if (_sameAs(next)) return;
    _prefs = next;
    notifyListeners();
    await _save();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final next = _prefs.reorder(oldIndex, newIndex, FieldCatalog.all);
    if (_sameAs(next)) return;
    _prefs = next;
    notifyListeners();
    await _save();
  }

  /// 设默认值。[value] 为 null = 恢复字段自带默认。
  Future<void> setDefault(String id, String? value) async {
    final field = FieldCatalog.byId(id);
    if (field == null || !field.defaultEditable) return;
    // 传进来的值必须在档位里，否则清掉这条覆盖（回到字段自带默认），
    // 而不是存一个界面上画不出来的值
    final valid = value != null && field.options.any((o) => o.value == value);
    final next = _prefs.withDefault(id, valid ? value : null);
    if (_sameAs(next)) return;
    _prefs = next;
    notifyListeners();
    await _save();
  }

  Future<void> reset() async {
    _prefs = FieldPrefs.initial();
    notifyListeners();
    await _save();
  }

  bool _sameAs(FieldPrefs other) =>
      other.encode() == _prefs.encode();

  Future<void> _save() => _settings.set(SettingsKeys.fieldPrefs, _prefs.encode());
}
