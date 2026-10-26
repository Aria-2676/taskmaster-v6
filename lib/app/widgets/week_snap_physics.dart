import 'package:flutter/gestures.dart' show kMinFlingVelocity;
import 'package:flutter/widgets.dart';

/// 按周吸附的滚动物理 —— 翻页手感的来源。
///
/// 两件事必须分清：
/// - **翻一周**要"顿"：短促、末端带一点过冲，落点那一下能听见/看见"咔"。
/// - **快甩多周**要"顺"：长距离滑行，不要中途一顿一顿。
///
/// 所以这里不是一个固定弹簧，而是按目标周数在两组参数之间插值：
/// 1 周以内用"脆"的（硬、略欠阻尼），5 周以上用"顺"的（软、临界阻尼）。
///
/// 早先的实现是"监听 ScrollEndNotification 再 animateTo"，那是从零速度起跑的位移，
/// 无论时长怎么调都只是"平移得快慢"，做不出落点。
class WeekSnapPhysics extends ScrollPhysics {
  const WeekSnapPhysics({required this.weekExtent, super.parent});

  /// 一周的像素宽度（格子按屏宽均分，所以等于视口宽度）
  final double weekExtent;

  // ---- 单周翻页：硬 + 欠阻尼，末端约 5% 过冲（360dp 屏约 19dp），落点"啪"一下 ----
  static const double _snapMass = 0.6;
  static const double _snapStiffness = 480;
  static const double _snapRatio = 0.68;

  // ---- 快甩多周：软 + 临界阻尼，长距离滑行不抖 ----
  static const double _glideMass = 0.9;
  static const double _glideStiffness = 140;
  static const double _glideRatio = 1.0;

  /// 目标不超过这个周数时用最"脆"的参数
  static const double _snapWeeks = 1;

  /// 目标超过这个周数时用最"顺"的参数；中间线性过渡
  static const double _glideWeeks = 5;

  /// 手感系数：每秒扫过 1 个 weekExtent 的速度，折算成几周。
  /// 调大 → 甩一下翻更多周；调小 → 更难滑远。
  static const double _weeksPerScreenPerSecond = 0.35;

  /// 只要判定为 fling，至少走一周（这是最高频的操作）
  static const double _minWeeksPerFling = 1;

  /// 一次 fling 最多跨多少周（防止意外的大速度把日历甩飞）
  static const double _maxWeeksPerFling = 20;

  static SpringDescription _springFor(double weeks) {
    final double t =
        ((weeks - _snapWeeks) / (_glideWeeks - _snapWeeks)).clamp(0.0, 1.0);
    return SpringDescription.withDampingRatio(
      mass: _lerp(_snapMass, _glideMass, t),
      stiffness: _lerp(_snapStiffness, _glideStiffness, t),
      ratio: _lerp(_snapRatio, _glideRatio, t),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  WeekSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      WeekSnapPhysics(weekExtent: weekExtent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (weekExtent <= 0 ||
        !position.hasContentDimensions ||
        position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }

    final double page = position.pixels / weekExtent;
    final double minPage = position.minScrollExtent / weekExtent;
    final double maxPage = position.maxScrollExtent / weekExtent;
    final double fling = velocity.abs();

    final double targetPage;
    final double weeks;
    if (fling < kMinFlingVelocity) {
      // 按住不动后松手：就近归位，不额外翻页（PageView 的标准行为）
      targetPage = page.roundToDouble();
      weeks = (targetPage - page).abs();
    } else {
      final double direction = velocity.sign;
      // 从"当前所在整周"起步，避免 0.98 周时被算成往前两周
      final double base =
          direction > 0 ? page.floorToDouble() : page.ceilToDouble();
      weeks = (fling / weekExtent * _weeksPerScreenPerSecond)
          .clamp(_minWeeksPerFling, _maxWeeksPerFling);
      targetPage = (base + direction * weeks).roundToDouble();
    }

    final double target = targetPage.clamp(minPage, maxPage) * weekExtent;
    if ((target - position.pixels).abs() < 0.5) return null;

    return ScrollSpringSimulation(
      _springFor(weeks),
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}
