import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/data/v6_schema.dart';
import '../../core/extension/extension_hook.dart';
import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import '../models/editor_form.dart';
import '../models/task.dart';

/// 首页的数据状态。**只持有"当前这一天"的任务**，不做全量缓存。
///
/// 之所以不用 Provider 包：v6 主包的外壳只需要一个可监听对象，
/// `ChangeNotifier` + `ListenableBuilder` 已经够，少一层依赖少一个失效点。
class TaskStore extends ChangeNotifier {
  TaskStore(this._repo, this._settings);

  final TaskRepository _repo;
  final SettingsRepository _settings;

  DateTime _day = DateTime.now();
  List<Task> _tasks = const <Task>[];
  List<Task> _overdue = const <Task>[];
  List<Tag> _tags = const <Tag>[];
  bool _loading = true;
  bool _ready = false;
  bool _settingsLoaded = false;
  bool _confirmBeforeDelete = true;
  bool _recycleBinEnabled = false;
  int _retentionDays = SettingsKeys.defaultRetentionDays;
  EditorForm _editorForm = EditorForm.sheet;
  String? _tagFilter;

  DateTime get day => _day;
  List<Task> get tasks => _tasks;
  List<Tag> get tags => _tags;
  bool get loading => _loading;

  /// 首次加载是否已经完成。**只用于"要不要显示全屏 loading"**。
  ///
  /// 不能用 `loading` 来判断：切日期时如果把整个 body 换成加载圈，
  /// 日历条会被销毁再重建，滚动位置随之跳回选中日期那一周，
  /// 看起来就是"点一下日期，日历条自己滑了一下"。
  bool get ready => _ready;

  String? get tagFilter => _tagFilter;

  /// 删除前是否弹确认框。默认开，用户勾过"不再提醒"后为 false。
  bool get confirmBeforeDelete => _confirmBeforeDelete;

  Future<void> setConfirmBeforeDelete(bool value) async {
    if (_confirmBeforeDelete == value) return;
    _confirmBeforeDelete = value;
    notifyListeners();
    await _settings.setBool(SettingsKeys.confirmBeforeDelete, value);
  }

  /// 删除后是否先进回收站。**默认关** —— 默认直接删掉，不留垃圾。
  bool get recycleBinEnabled => _recycleBinEnabled;

  Future<void> setRecycleBinEnabled(bool value) async {
    if (_recycleBinEnabled == value) return;
    _recycleBinEnabled = value;
    notifyListeners();
    await _settings.setBool(SettingsKeys.recycleBinEnabled, value);
  }

  /// 编辑页形态。默认底部弹层：新建任务时不离场，还能看见底下的列表。
  EditorForm get editorForm => _editorForm;
  Future<void> setEditorForm(EditorForm form) async {
    if (_editorForm == form) return;
    _editorForm = form;
    notifyListeners();
    await _settings.set(SettingsKeys.editorForm, form.id);
  }

  /// 回收站保留天数。到期由启动时的清理任务物理删除。
  int get retentionDays => _retentionDays;

  /// 改保留时长。**改短会立刻触发一次清理**，返回被清掉的条数。
  ///
  /// 为什么不让"倒计时"自己生效：清理是机会式的（启动时扫一遍），
  /// 没有后台定时器。如果只改设置不清理，用户会看到"即将清理"却一直挂着，
  /// 直到下次冷启动 —— 界面在骗人。
  Future<int> setRetentionDays(int days) async {
    if (_retentionDays == days) return 0;
    _retentionDays = days;
    notifyListeners();
    await _settings.setInt(SettingsKeys.recycleRetentionDays, days);
    return purgeRecycle();
  }

  /// 按当前保留时长清理过期条目，返回清掉的条数。
  Future<int> purgeRecycle() =>
      _repo.purgeRecycleOlderThan(Duration(days: _retentionDays));

  /// 如果改成 [days] 天，会立刻清掉几条。改短前先问一句用。
  Future<int> countRecycleExpiringWith(int days) =>
      _repo.countRecycleOlderThan(Duration(days: days));

  /// 按标签筛选后的列表。`null` 表示"全部"。
  List<Task> get visible => _tagFilter == null
      ? _tasks
      : _tasks.where((t) => t.tags.any((tag) => tag.name == _tagFilter)).toList();

  /// 逾期：比当前日期更早、还没做完的任务。**跟标签筛选一样过滤**，
  /// 否则筛了「工作」还会冒出「学习」的逾期任务。
  List<Task> get overdue => _tagFilter == null
      ? _overdue
      : _overdue
          .where((t) => t.tags.any((tag) => tag.name == _tagFilter))
          .toList();

  /// 未经过滤的逾期总数（首页标题用它，避免"筛了标签后数字忽大忽小"的困惑——
  /// 什么时候显示都跟列表一致，所以仍然用过滤后的长度）
  int get overdueCount => overdue.length;

  /// 把一条任务挪到某天。「逾期」区块的"移到今天"用它。
  Future<void> moveToDay(Task task, DateTime day) async {
    await _repo.patch(task.id, <String, Object?>{TaskCol.cplTime: TaskDate.dayKey(day)});
    await load();
  }

  /// 把当前逾期任务全部挪到 [day]，返回挪了几条。
  Future<int> moveAllOverdueTo(DateTime day) async {
    final targets = List<Task>.of(_overdue);
    if (targets.isEmpty) return 0;
    for (final task in targets) {
      await _repo.patch(task.id, <String, Object?>{TaskCol.cplTime: TaskDate.dayKey(day)});
    }
    await load();
    return targets.length;
  }

  void setTagFilter(String? name) {
    if (_tagFilter == name) return;
    _tagFilter = name;
    notifyListeners();
  }

  Future<void> load([DateTime? day]) async {
    if (day != null) {
      _day = DateTime(day.year, day.month, day.day);
    }
    _loading = true;
    notifyListeners();

    if (!_settingsLoaded) {
      _settingsLoaded = true;
      _confirmBeforeDelete = await _settings.getBool(
        SettingsKeys.confirmBeforeDelete,
        fallback: true,
      );
      _recycleBinEnabled = await _settings.getBool(
        SettingsKeys.recycleBinEnabled,
        fallback: false,
      );
      _retentionDays = await _settings.getInt(
        SettingsKeys.recycleRetentionDays,
        fallback: SettingsKeys.defaultRetentionDays,
      );
      _editorForm = EditorForm.parse(
        await _settings.get(SettingsKeys.editorForm),
      );
    }

    _tasks = await _repo.tasksOn(_day);
    _overdue = await _repo.overdueBefore(_day);
    _tags = await _repo.allTags();
    _loading = false;
    _ready = true;
    notifyListeners();
  }

  Future<void> toggle(Task task) async {
    final next = !task.isDone;
    await _repo.setDone(task.id, next);
    if (next) {
      // **不 await**：钩子是通知，单个订阅方超时 500ms 也必须放行主流程，
      // 而且用户勾完要立刻看到卡片变化，不能等插件。
      unawaited(HookBus.instance.emit(
        HookId.taskCompleted,
        payload: task.toHookPayload(),
      ));
    }
    await load();
  }

  Future<void> add(
    String title, {
    String? description,
    int? estimatedMinutes,
    String priority = 'white',
    List<int> tagIds = const <int>[],
    DateTime? day,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    await _repo.insert(
      title: trimmed,
      day: day ?? _day,
      description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      priority: priority,
      estimatedMinutes: estimatedMinutes,
      tagIds: tagIds,
    );
    await load();
  }

  /// 保存编辑。标题为空直接拒绝（界面上也拦了一层，这里是最后一道）。
  Future<void> updateTask(
    Task task, {
    required String title,
    String? description,
    required DateTime dueDate,
    required String priority,
    int? estimatedMinutes,
    required List<int> tagIds,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const TagException('标题不能为空');
    }
    await _repo.update(
      task.id,
      title: trimmed,
      description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      day: dueDate,
      priority: priority,
      estimatedMinutes: estimatedMinutes,
      tagIds: tagIds,
    );
    await load();
  }

  // ---- 标签 ----

  /// 每个标签被多少任务使用（标签管理页用）
  Future<Map<int, int>> tagUsage() => _repo.tagUsage();

  Future<void> addTag(String name, String color) async {
    final trimmed = _checkTagName(name);
    await _repo.insertTag(Tag(id: 0, name: trimmed, color: color));
    await load();
  }

  Future<void> renameTag(Tag tag, String name) async {
    final trimmed = _checkTagName(name, ignoreId: tag.id);
    await _repo.renameTag(tag.id, trimmed);
    // 筛选条件存的是**名字**，改名后要跟着改，否则筛选会指向一个不存在的标签
    if (_tagFilter == tag.name) _tagFilter = trimmed;
    await load();
  }

  Future<void> setTagColor(Tag tag, String color) async {
    await _repo.setTagColor(tag.id, color);
    await load();
  }

  Future<void> deleteTag(Tag tag) async {
    await _repo.deleteTag(tag.id);
    // 正在按这个标签筛选时，标签没了就得回到"全部"，
    // 否则列表会一直是空的，用户还以为是任务丢了
    if (_tagFilter == tag.name) _tagFilter = null;
    await load();
  }

  String _checkTagName(String raw, {int? ignoreId}) {
    final name = raw.trim();
    if (name.isEmpty) throw const TagException('标签名不能为空');
    if (_tags.any((t) => t.name == name && t.id != ignoreId)) {
      throw TagException('已经有叫「$name」的标签了');
    }
    return name;
  }

  /// 先摘内存、再删库。
  ///
  /// 顺序不能反：左滑删除时 `Dismissible.onDismissed` 会立刻把 widget 移走，
  /// 如果等数据库回来才 `notifyListeners`，列表重建时会撞上
  /// "dismissed Dismissible is still part of the tree"。
  Future<void> remove(Task task) async {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index < 0) return;

    _tasks = List<Task>.of(_tasks)..removeAt(index);
    notifyListeners();

    try {
      await _repo.delete(task.id, toRecycle: _recycleBinEnabled);
      // 只有真进了回收站才发事件：物理删除是"没了"，插件没有可操作的对象。
      if (_recycleBinEnabled) {
        unawaited(HookBus.instance.emit(
          HookId.taskRecycled,
          payload: task.toHookPayload(),
        ));
      }
    } catch (_) {
      // 删库失败就把那一条放回原位，界面不能骗人
      final restored = List<Task>.of(_tasks)
        ..insert(index.clamp(0, _tasks.length), task);
      _tasks = restored;
      notifyListeners();
      rethrow;
    }
    await load();
  }
}

/// 标签操作的业务错误（名字为空、重名）。**用异常而不是返回值**，
/// 因为调用方（弹窗）需要把消息原样显示在输入框下面，
/// 用 bool 会把"为什么不行"丢掉。
class TagException implements Exception {
  const TagException(this.message);

  final String message;

  @override
  String toString() => message;
}
