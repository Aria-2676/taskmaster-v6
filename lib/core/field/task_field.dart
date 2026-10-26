// 任务字段的**声明**（主包唯一拥有）。
//
// 为什么要这一层：v5 是「每个字段配一个硬编码 boolean 开关」——
// 想加一个字段，要同时改模型、改编辑页、改迁移、改设置页四处。
// 换成这张表之后，加字段只做两件事：
//   1. 库里加一列（可空，零回填）
//   2. 这里加一条
// 编辑页、字段管理页、默认值解析全部由表驱动，不再各写一遍。
//
// **字段归主包，插件不贡献字段**：插件只提供整页（已画好的页面），
// 它拿不到也不该改字段定义。见 docs/editor-extension-plan.md。

/// 字段的输入形态。决定编辑页怎么画，也决定「默认值能不能改」。
enum TaskFieldType {
  /// 单行文本
  text,

  /// 多行文本
  multiline,

  /// 日期（到天）
  date,

  /// 颜色优先级（红/橙/黄/蓝/白）
  priority,

  /// 标签多选
  tags,

  /// 时长（分钟），'' 表示不设
  minutes,
}

/// 一个可选档位。[value] 为空串表示「不设」——**不是 null**：
/// null 的含义是"用字段默认值"，空串是"用户明确选了不要"。
/// 这两者在界面上是两件事，混起来就会出现"清空了又冒出来"。
class TaskFieldOption {
  const TaskFieldOption(this.value, this.label);

  final String value;
  final String label;

  bool get isNone => value.isEmpty;
}

/// 字段声明。
class TaskField {
  const TaskField({
    required this.id,
    required this.label,
    required this.type,
    this.locked = false,
    this.options = const <TaskFieldOption>[],
    this.defaultValue,
    this.hint,
  });

  /// 稳定 id，会写进 settings 的偏好 JSON。**改名可以，改 id 等于丢配置**。
  final String id;

  final String label;
  final TaskFieldType type;

  /// 核心字段：不可关闭（关掉任务就不可用了）
  final bool locked;

  /// 枚举类字段的档位。空表示不是枚举字段（也就不能配默认值）
  final List<TaskFieldOption> options;

  /// 字段自带的默认值。
  ///
  /// **null 也是一个合法默认值**，意思是"默认就是不设"。用户可以在字段管理里
  /// 覆盖它；覆盖值只影响显示和新建时的预填，**绝不回写已有任务**。
  final String? defaultValue;

  /// 字段管理页里的一句话说明
  final String? hint;

  bool get hasOptions => options.isNotEmpty;

  /// 能不能让用户改默认值：只有枚举类才有意义。
  /// 文本字段的"默认值"要么是空要么是上次输入，不叫默认，叫记忆。
  bool get defaultEditable => hasOptions;
}

/// 主包字段表。
///
/// 顺序就是**首次安装时的默认顺序**。想调默认开关就改这里的 `defaultHidden`，
/// 但注意：已经装过的用户不会被改到（偏好一旦落库就以库里的为准）。
class FieldCatalog {
  const FieldCatalog._();

  static const TaskField title = TaskField(
    id: 'title',
    label: '标题',
    type: TaskFieldType.text,
    locked: true,
    hint: '唯一必填项',
  );

  static const TaskField dueDate = TaskField(
    id: 'due_date',
    label: '日期',
    type: TaskFieldType.date,
    locked: true,
    hint: '任务属于哪一天',
  );

  static const TaskField priority = TaskField(
    id: 'priority',
    label: '优先级',
    type: TaskFieldType.priority,
    defaultValue: 'white',
    options: <TaskFieldOption>[
      TaskFieldOption('red', '红'),
      TaskFieldOption('orange', '橙'),
      TaskFieldOption('yellow', '黄'),
      TaskFieldOption('blue', '蓝'),
      TaskFieldOption('white', '白'),
    ],
  );

  static const TaskField tags = TaskField(
    id: 'tags',
    label: '标签',
    type: TaskFieldType.tags,
  );

  static const TaskField description = TaskField(
    id: 'description',
    label: '描述',
    type: TaskFieldType.multiline,
    hint: '关闭只是不显示，内容不会删',
  );

  static const TaskField minutes = TaskField(
    id: 'estimated_minutes',
    label: '预计时长',
    type: TaskFieldType.minutes,
    options: <TaskFieldOption>[
      TaskFieldOption('', '不设'),
      TaskFieldOption('15', '15 分钟'),
      TaskFieldOption('30', '30 分钟'),
      TaskFieldOption('60', '60 分钟'),
      TaskFieldOption('120', '120 分钟'),
    ],
    hint: '货币插件按它计价',
  );

  /// 全部字段，顺序即默认顺序
  static const List<TaskField> all = <TaskField>[
    title,
    dueDate,
    priority,
    tags,
    description,
    minutes,
  ];

  /// 首次安装时默认关闭的字段。核心字段不许放进来（会有断言兜着）。
  static const Set<String> defaultHidden = <String>{};

  static TaskField? byId(String id) {
    for (final field in all) {
      if (field.id == id) return field;
    }
    return null;
  }
}
