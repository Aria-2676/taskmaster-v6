import 'package:flutter/material.dart';

import '../models/calendar_strip_style.dart';
import 'week_snap_physics.dart';

/// 第一屏顶部的日历条。两种形态都由主包绘制。
///
/// 格子宽度**按屏宽均分**（屏宽 / 7），不写死像素——否则窄屏放不下整周、宽屏又留下空档。
/// 可滑形态的吸附由 [WeekSnapPhysics] 负责（滚动模拟，不是手动 animateTo），
/// 松手后有翻页的惯性与回位感；不想要吸附就把 [snapToWeek] 改成 false。
class CalendarStrip extends StatefulWidget {
  const CalendarStrip({
    super.key,
    required this.selected,
    required this.onSelect,
    this.style = CalendarStripStyle.scroll,
    this.resetSignal = 0,
    this.marks,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelect;
  final CalendarStripStyle style;

  /// 值变化时把可视区滚回今天（对应「双击顶栏日期」）
  final int resetSignal;

  /// 插槽 `slot.calendarMarks` 的数据：key 为当天零点，value 为标记类型。
  /// **主包决定怎么画**（插件只给数据），没有插件时传 null。
  final Map<DateTime, String>? marks;

  @override
  State<CalendarStrip> createState() => _CalendarStripState();
}

class _CalendarStripState extends State<CalendarStrip> {
  static const List<String> _weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];

  /// 想把吸附整个关掉就改这里
  static const bool snapToWeek = true;

  static const int _weeksBefore = 26;
  static const int _weeksAfter = 26;
  static const int _totalDays = (_weeksBefore + _weeksAfter + 1) * 7;

  /// 起点对齐到周一，这样"周"的边界就是每 7 格一次
  late final DateTime _anchor = _mondayOf(_dateOnly(DateTime.now()))
      .subtract(const Duration(days: _weeksBefore * 7));

  final ScrollController _controller = ScrollController();
  double _cellWidth = 0;
  bool _needsInitialJump = true;

  @override
  void didUpdateWidget(covariant CalendarStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetSignal != widget.resetSignal &&
        widget.style == CalendarStripStyle.scroll) {
      _scrollTo(widget.selected);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _offsetFor(DateTime date, double cellWidth) {
    final index = date.difference(_anchor).inDays.clamp(0, _totalDays - 1);
    final weekStart = index - (index % 7);
    return weekStart * cellWidth;
  }

  void _scrollTo(DateTime date) {
    if (_cellWidth <= 0 || !_controller.hasClients) return;
    final maxExtent = _controller.position.maxScrollExtent;
    final target = _offsetFor(date, _cellWidth).clamp(0.0, maxExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _maybeInitialJump(double cellWidth) {
    if (!_needsInitialJump || cellWidth <= 0) return;
    _needsInitialJump = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final maxExtent = _controller.position.maxScrollExtent;
      _controller.jumpTo(_offsetFor(widget.selected, cellWidth).clamp(0.0, maxExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.style == CalendarStripStyle.week) {
      return SizedBox(height: 58, child: _buildWeek(context));
    }

    return SizedBox(
      height: 58,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellWidth = constraints.maxWidth / 7;
          _cellWidth = cellWidth;
          _maybeInitialJump(cellWidth);
          return _buildScroll(context, cellWidth);
        },
      ),
    );
  }

  Widget _buildWeek(BuildContext context) {
    final monday = _mondayOf(widget.selected);
    return Row(
      children: List<Widget>.generate(7, (i) {
        final day = monday.add(Duration(days: i));
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: _buildCell(context, day),
          ),
        );
      }),
    );
  }

  Widget _buildScroll(BuildContext context, double cellWidth) {
    return ListView.builder(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      itemExtent: cellWidth,
      itemCount: _totalDays,
      // 吸附交给滚动模拟：松手瞬间的速度会被带进 spring，
      // 所以有"甩出去再被拉住"的翻页感，而不是从零速度平移过去。
      physics: snapToWeek
          ? WeekSnapPhysics(
              weekExtent: cellWidth * 7,
              parent: const ClampingScrollPhysics(),
            )
          : null,
      itemBuilder: (context, i) {
        final day = _anchor.add(Duration(days: i));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: _buildCell(context, day),
        );
      },
    );
  }

  Widget _buildCell(BuildContext context, DateTime day) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final selected = _sameDay(day, widget.selected);
    final isToday = _sameDay(day, DateTime.now());

    // 标记由插件给"是什么"，画成什么样由主包决定（避免插件自定样式导致风格割裂）
    final mark = widget.marks?[_dateOnly(day)];
    final markColor = selected
        ? scheme.onPrimary
        : switch (mark) {
            'done' => scheme.primary,
            'focus' => const Color(0xFFFB8C00),
            null => Colors.transparent,
            _ => scheme.primary.withValues(alpha: 0.55),
          };

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onSelect(day),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isToday && !selected
              ? Border.all(color: scheme.primary.withValues(alpha: 0.4))
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  _weekdays[day.weekday - 1],
                  style: TextStyle(fontSize: 11, color: selected ? scheme.onPrimary : muted),
                ),
                const SizedBox(height: 2),
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ),
            if (mark != null)
              Positioned(
                bottom: 3,
                child: Container(
                  // 给测试一个稳定的锚点：标记点本身没有文案
                  key: ValueKey<String>('cal-mark-${day.year}-${day.month}-${day.day}'),
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: markColor, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _mondayOf(DateTime d) => _dateOnly(d).subtract(Duration(days: d.weekday - 1));

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
