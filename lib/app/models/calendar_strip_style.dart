/// 日历条的两种形态。
///
/// 这是**呈现策略**，不是功能扩展：两种形态都由主包绘制，切换只是换一个渲染分支。
/// 所以它放在设置里，而不是做成插件——做成插件只会多一层安装流程，
/// 换不来任何主包没实现的能力（插件无法提供 Dart 代码）。
enum CalendarStripStyle {
  /// 固定一周：周一到周日，一眼看全这周
  week('week', '固定一周'),

  /// 横向可滑：可以滑到很远的日子，接近 v5 的手感
  scroll('scroll', '横向可滑');

  const CalendarStripStyle(this.id, this.label);

  final String id;
  final String label;

  static CalendarStripStyle fromId(String? id) =>
      values.firstWhere((s) => s.id == id, orElse: () => scroll);
}
