import 'package:flutter/material.dart';

import '../../core/field/task_field.dart';
import '../models/editor_form.dart';
import '../models/task.dart';
import '../state/field_store.dart';
import '../state/task_store.dart';

/// 编辑页关闭时的结果。壳层靠它决定提示什么。
enum TaskEditOutcome { saved, deleted }

/// 打开任务编辑。**按当前设置决定它是底部弹层还是全屏页**。
///
/// 调用方不该关心形态 —— 这行是唯一入口，切换形态不影响任何调用点。
Future<TaskEditOutcome?> showTaskEditor(
  BuildContext context, {
  required TaskStore store,
  FieldStore? fields,
  Task? task,
  DateTime? initialDay,
  Future<bool> Function()? onDelete,
  EditorForm? form,
}) {
  final target = form ?? store.editorForm;
  if (target == EditorForm.full) {
    return Navigator.of(context).push<TaskEditOutcome>(
      MaterialPageRoute<TaskEditOutcome>(
        builder: (_) => TaskEditorPage(
          store: store,
          fields: fields,
          task: task,
          initialDay: initialDay,
          onDelete: onDelete,
        ),
      ),
    );
  }
  return showModalBottomSheet<TaskEditOutcome>(
    context: context,
    // 有键盘时必须用这个，否则输入框会被弹层裁掉
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    // 两个都关掉，原因是**改动不能静默丢**：
    // 拖拽关闭和点遮罩关闭都是 `Navigator.pop`，绕过 PopScope，
    // 用户改了半页句子一拉就没了，连"放弃修改？"都问不到。
    // 关闭只留左上角 X（走 _cancel，有改动会先确认）。
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _EditorSheet(
      store: store,
      fields: fields,
      task: task,
      initialDay: initialDay,
      onDelete: onDelete,
    ),
  );
}

/// 全屏容器。**只有壳**，内容和弹层里那份完全一样。
///
/// 保留 AppBar 而不是让内容自带标题栏：全屏时用户要的是"返回/保存"在
/// 系统栏位置（也是返回手势落点），弹层时它们才该缩进到弹层顶部。
class TaskEditorPage extends StatelessWidget {
  const TaskEditorPage({
    super.key,
    required this.store,
    this.fields,
    this.task,
    this.initialDay,
    this.onDelete,
  });

  final TaskStore store;
  final FieldStore? fields;
  final Task? task;
  final DateTime? initialDay;
  final Future<bool> Function()? onDelete;

  bool get isCreating => task == null;

  @override
  Widget build(BuildContext context) {
    final key = GlobalKey<TaskEditorContentState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isCreating ? '新建任务' : '编辑任务',
          style: const TextStyle(fontSize: 16),
        ),
        actions: <Widget>[
          Builder(
            builder: (context) => TextButton(
              onPressed: () => key.currentState?.save(),
              child: Text(isCreating ? '添加' : '保存'),
            ),
          ),
        ],
      ),
      body: TaskEditorContent(
        key: key,
        store: store,
        fields: fields,
        task: task,
        initialDay: initialDay,
        onDelete: onDelete,
        form: EditorForm.full,
      ),
    );
  }
}

/// 弹层容器。上拖可到全屏，右上角一键切换。
class _EditorSheet extends StatefulWidget {
  const _EditorSheet({
    required this.store,
    this.fields,
    this.task,
    this.initialDay,
    this.onDelete,
  });

  final TaskStore store;
  final FieldStore? fields;
  final Task? task;
  final DateTime? initialDay;
  final Future<bool> Function()? onDelete;

  @override
  State<_EditorSheet> createState() => _EditorSheetState();
}

class _EditorSheetState extends State<_EditorSheet> {
  static const double _collapsed = 0.62;

  final DraggableScrollableController _controller =
      DraggableScrollableController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _expanded => _controller.isAttached && _controller.size > 0.96;

  Future<void> _toggle() async {
    if (!_controller.isAttached) return;
    await _controller.animateTo(
      _expanded ? _collapsed : 1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (mounted) setState(() {}); // 换图标
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: keyboard),
      child: DraggableScrollableSheet(
        controller: _controller,
        initialChildSize: _collapsed,
        // 最小就是 62%：再往下拖不会把面板拖没 —— 那等于没有任何提示地放弃修改。
        minChildSize: _collapsed,
        maxChildSize: 1,
        expand: false,
        snap: true,
        snapSizes: const <double>[_collapsed, 1],
        // **默认 true**：拖到最小高度时直接 pop 掉整个路由。
        // 表现就是"往下拉一把，编辑面板没了"，而且绕过了"放弃修改？"确认。
        // 关掉它，最小高度就只是停住，关闭只能走 X。
        shouldCloseOnMinExtent: false,
        builder: (context, scrollController) {
          return Material(
            color: scheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: TaskEditorContent(
              store: widget.store,
              fields: widget.fields,
              task: widget.task,
              initialDay: widget.initialDay,
              onDelete: widget.onDelete,
              scrollController: scrollController,
              showHeader: true,
              form: EditorForm.sheet,
              expandIcon: _expanded ? Icons.close_fullscreen : Icons.open_in_full,
              onToggleExpand: _toggle,
            ),
          );
        },
      ),
    );
  }
}

/// 编辑页主体。**新建和编辑用同一份**，差别只有"有没有原值"。
///
/// 字段从 [FieldStore] 来，不是硬编码：用户在字段管理里关掉哪一项，
/// 这里就少画一行，顺序也跟着走。
///
/// 默认值的规则要分清两种模式：**新建时按默认值落库**（用户设默认就是想要这个结果），
/// **编辑已有任务时不回填**（否则会改写历史数据）。见 [save]。
class TaskEditorContent extends StatefulWidget {
  const TaskEditorContent({
    super.key,
    required this.store,
    this.fields,
    this.task,
    this.initialDay,
    this.onDelete,
    this.scrollController,
    this.showHeader = false,
    this.form = EditorForm.full,
    this.expandIcon,
    this.onToggleExpand,
  });

  final TaskStore store;
  final FieldStore? fields;
  final Task? task;
  final DateTime? initialDay;
  final Future<bool> Function()? onDelete;

  /// 弹层把 DraggableScrollableSheet 的控制器传进来，拖列表才能改变高度
  final ScrollController? scrollController;

  /// 弹层需要自己的一行标题栏（没有 AppBar）
  final bool showHeader;

  final EditorForm form;
  final IconData? expandIcon;
  final VoidCallback? onToggleExpand;

  bool get isCreating => task == null;

  @override
  State<TaskEditorContent> createState() => TaskEditorContentState();
}

class TaskEditorContentState extends State<TaskEditorContent> {
  late final TextEditingController _title =
      TextEditingController(text: widget.task?.title ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.task?.description ?? '');

  late DateTime _day = widget.task?.dueDate ??
      widget.initialDay ??
      DateTime.now();

  /// 优先级列非空，历史任务一定有值；只有新建才需要默认值
  late String _priority = widget.task?.priority ??
      widget.fields?.defaultOf(FieldCatalog.priority) ??
      'white';

  late int? _minutes = widget.task?.estimatedMinutes ??
      _parseMinutes(widget.fields?.defaultOf(FieldCatalog.minutes));

  late final Set<int> _tagIds =
      widget.task?.tags.map((t) => t.id).toSet() ?? <int>{};

  /// 用户动过的字段。**没动过 = 保存时写回原值（可能是 null）**，
  /// 这是"默认值不回写"的实现点。
  final Set<String> _touched = <String>{};

  String? _titleError;
  bool _dirty = false;
  bool _saving = false;
  bool _showHidden = false;

  bool get _isCreating => widget.task == null;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (_dirty) return;
    setState(() => _dirty = true);
  }

  void _touch(String id) {
    _touched.add(id);
    _dirty = true;
  }

  /// 这一项显示的是"你设过的默认值"而不是你这次选的 —— 界面上要标出来。
  ///
  /// 只有**用户亲手改过默认值**才标：优先级这类字段永远有值，
  /// 没改过还挂个「默认」牌子就是纯噪音。
  bool _showsDefault(String id) =>
      _isCreating &&
      !_touched.contains(id) &&
      (widget.fields?.hasDefaultOverride(id) ?? false);

  Future<void> save() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '标题不能为空');
      return;
    }

    setState(() {
      _saving = true;
      _titleError = null;
    });

    try {
      final existing = widget.task;
      // 默认值在两种模式下的处理**不一样**，这里必须分开：
      //
      // - 新建：没动过就按默认值落库。用户去设"默认 60 分钟"，意思就是
      //   "以后建的任务都是 60"，只预填不落库 = 设置看起来没生效
      //   （卡片上不显示时长，货币插件也拿不到值）。
      // - 编辑：没动过就保持原值，**绝不拿默认值回填**。
      //   否则改一次默认值、再打开一次老任务，历史数据就被悄悄改写了。
      final minutes = existing != null && !_touched.contains(FieldCatalog.minutes.id)
          ? existing.estimatedMinutes
          : _minutes;

      if (existing == null) {
        await widget.store.add(
          title,
          description: _description.text,
          day: _day,
          priority: _priority,
          estimatedMinutes: minutes,
          tagIds: _tagIds.toList(),
        );
      } else {
        await widget.store.updateTask(
          existing,
          title: title,
          description: _description.text,
          dueDate: _day,
          priority: _priority,
          estimatedMinutes: minutes,
          tagIds: _tagIds.toList(),
        );
      }
      if (!mounted) return;
      _dirty = false;
      Navigator.of(context).pop(TaskEditOutcome.saved);
    } on TagException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _titleError = error.message;
      });
    }
  }

  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    if (onDelete == null) return;
    final deleted = await onDelete();
    if (!mounted || !deleted) return;
    _dirty = false;
    Navigator.of(context).pop(TaskEditOutcome.deleted);
  }

  Future<void> _cancel() async {
    if (_dirty) {
      final leave = await _confirmDiscard();
      if (!mounted || !leave) return;
      _dirty = false;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime(DateTime.now().year + 5),
      helpText: '选择日期',
    );
    if (picked == null) return;
    setState(() {
      _day = DateTime(picked.year, picked.month, picked.day);
      _touch(FieldCatalog.dueDate.id);
    });
  }

  Future<bool> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃修改？', style: TextStyle(fontSize: 16)),
        content: const Text('这次的修改还没保存。', style: TextStyle(fontSize: 13.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  // ---- 字段取值 ----

  List<TaskField> get _layout {
    final fields = widget.fields;
    if (fields == null || !fields.loaded) return FieldCatalog.all;
    return fields.enabled;
  }

  /// 被关掉、但这条任务里确实有内容的字段。**要提示**，
  /// 否则用户会以为"关了个开关，描述就没了"。
  List<TaskField> get _hiddenWithValues {
    final fields = widget.fields;
    if (fields == null || !fields.loaded) return const <TaskField>[];
    return fields.prefs.hiddenWithValue(FieldCatalog.all, _hasContent);
  }

  bool _hasContent(TaskField field) {
    return switch (field.type) {
      TaskFieldType.multiline => _description.text.trim().isNotEmpty,
      TaskFieldType.minutes =>
        widget.task?.estimatedMinutes != null ||
            (_touched.contains(FieldCatalog.minutes.id) && _minutes != null),
      // 优先级永远有值（列非空），把它算进来会让提示永远挂着
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];

    for (final field in _layout) {
      rows.add(_buildField(field, scheme));
      rows.add(const SizedBox(height: 18));
    }

    if (_showHidden) {
      for (final field in _hiddenWithValues) {
        rows.add(_buildField(field, scheme));
        rows.add(const SizedBox(height: 18));
      }
    }

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (!context.mounted || !leave) return;
        _dirty = false;
        Navigator.of(context).pop();
      },
      child: Column(
        children: <Widget>[
          if (widget.showHeader) _header(scheme),
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: <Widget>[
                ...rows,
                if (!_showHidden && _hiddenWithValues.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _showHidden = true),
                      icon: Icon(Icons.visibility_off_outlined, size: 16, color: scheme.outline),
                      label: Text(
                        '已隐藏 ${_hiddenWithValues.map((f) => f.label).join('、')}（内容还在）',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ),
                if (!_isCreating) ...<Widget>[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: _saving ? null : _delete,
                      icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                      label: Text('删除任务', style: TextStyle(color: scheme.error)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
      child: Row(
        children: <Widget>[
          // 用 X 而不是「取消」：弹层里「取消」会和日期选择器、确认框的
          // 「取消」撞在一起，同一个屏幕上出现两个"取消"会让人不知道取消哪个
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 20),
            onPressed: _cancel,
          ),
          Expanded(
            child: Center(
              child: Text(
                _isCreating ? '新建任务' : '编辑任务',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (widget.onToggleExpand != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: widget.form == EditorForm.sheet ? '展开 / 收起' : null,
              icon: Icon(widget.expandIcon ?? Icons.open_in_full, size: 18),
              onPressed: widget.onToggleExpand,
            ),
          TextButton(
            onPressed: _saving ? null : save,
            child: Text(_saving ? '保存中…' : (_isCreating ? '添加' : '保存')),
          ),
        ],
      ),
    );
  }

  // ---- 单个字段 ----

  Widget _buildField(TaskField field, ColorScheme scheme) {
    return switch (field.type) {
      TaskFieldType.text => _textField(field, scheme),
      TaskFieldType.multiline => _multilineField(field, scheme),
      TaskFieldType.date => _dateField(field, scheme),
      TaskFieldType.priority => _choiceField(field, scheme),
      TaskFieldType.minutes => _choiceField(field, scheme),
      TaskFieldType.tags => _tagsField(field, scheme),
    };
  }

  Widget _label(TaskField field, ColorScheme scheme) {
    final usingDefault = field.defaultEditable && _showsDefault(field.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Text(field.label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          if (usingDefault) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text('默认', style: TextStyle(fontSize: 9.5, color: scheme.outline)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _textField(TaskField field, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _title,
          autofocus: _isCreating && widget.form == EditorForm.sheet,
          maxLines: null,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: field.label,
            errorText: _titleError,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) {
            _markDirty();
            if (_titleError != null) setState(() => _titleError = null);
          },
        ),
      ],
    );
  }

  Widget _multilineField(TaskField field, ColorScheme scheme) {
    return TextField(
      controller: _description,
      maxLines: 3,
      minLines: 1,
      decoration: InputDecoration(
        labelText: '${field.label}（可留空）',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => _markDirty(),
    );
  }

  Widget _dateField(TaskField field, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(field, scheme),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _pickDate,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: <Widget>[
                Icon(Icons.event_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(_dayLabel(_day), style: const TextStyle(fontSize: 14)),
                const Spacer(),
                Icon(Icons.chevron_right, size: 18, color: scheme.outlineVariant),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _choiceField(TaskField field, ColorScheme scheme) {
    final isMinutes = field.type == TaskFieldType.minutes;

    String selected;
    if (isMinutes) {
      selected = _minutes == null ? '' : '$_minutes';
    } else {
      selected = _priority;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(field, scheme),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final option in field.options)
              _Choice(
                label: option.label,
                selected: selected == option.value,
                dimmed: _showsDefault(field.id),
                dotColor: isMinutes ? null : _priorityColor(option.value),
                onTap: () => setState(() {
                  if (isMinutes) {
                    _minutes = _parseMinutes(option.value);
                  } else {
                    _priority = option.value;
                  }
                  _touch(field.id);
                }),
              ),
          ],
        ),
      ],
    );
  }

  Widget _tagsField(TaskField field, ColorScheme scheme) {
    final tags = widget.store.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(field, scheme),
        if (tags.isEmpty)
          Text(
            '还没有标签，可在侧边栏「标签管理」里新建',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final tag in tags)
                FilterChip(
                  label: Text(tag.name),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: _tagIds.contains(tag.id) ? tag.displayColor : null,
                  ),
                  selected: _tagIds.contains(tag.id),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  selectedColor: tag.displayColor.withValues(alpha: 0.18),
                  onSelected: (value) => setState(() {
                    if (value) {
                      _tagIds.add(tag.id);
                    } else {
                      _tagIds.remove(tag.id);
                    }
                    _touch(field.id);
                  }),
                ),
            ],
          ),
      ],
    );
  }

  static int? _parseMinutes(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  static Color _priorityColor(String value) => switch (value) {
        'red' => const Color(0xFFE53935),
        'orange' => const Color(0xFFFB8C00),
        'yellow' => const Color(0xFFFDD835),
        'blue' => const Color(0xFF1E88E5),
        _ => const Color(0xFFBDBDBD),
      };

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    final diff = target.difference(today).inDays;
    const weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    final base =
        '${day.year}年${day.month}月${day.day}日 周${weekdays[day.weekday - 1]}';
    return switch (diff) {
      0 => '$base · 今天',
      1 => '$base · 明天',
      -1 => '$base · 昨天',
      _ => base,
    };
  }
}

/// 一个可点的档位（圆点 + 文字）。不用 ChoiceChip 是为了能带色点。
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
    this.dimmed = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dotColor;

  /// 显示的是默认值、用户还没动过 —— 用虚线感（低对比边框）区分
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: dimmed ? 0.06 : 0.10) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: dimmed ? 0.5 : 1)
                : scheme.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (dotColor != null) ...<Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
