/// 编辑页的形态。
///
/// 主体（字段）和容器（弹层/全屏）是分开的：同一份内容换壳而已。
/// 分成两个页面会立刻出现"某个字段只在一处能填"的老问题。
enum EditorForm {
  /// 底部弹层，可上拖到全屏。默认 —— 新建任务时不离场，
  /// 还能看见底下列表的日子和上下文。
  sheet('sheet', '底部弹层'),

  /// 全屏页。字段多、要专心填的时候更舒服。
  full('full', '全屏');

  const EditorForm(this.id, this.label);

  final String id;
  final String label;

  static EditorForm parse(String? raw) {
    for (final form in values) {
      if (form.id == raw) return form;
    }
    return EditorForm.sheet;
  }
}
