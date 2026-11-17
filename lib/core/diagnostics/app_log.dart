import 'dart:collection';

import 'package:flutter/foundation.dart';

/// 一条日志。
@immutable
class AppLogEntry {
  const AppLogEntry({required this.at, required this.tag, required this.message});

  final DateTime at;

  /// 从消息开头的 `[xxx]` 里取出来的分类。没有方括号前缀时为空串。
  final String tag;

  final String message;

  /// `14:03:27 [today] 加载计划块…`
  ///
  /// 只到秒、不带日期：日志面板里看的是"刚才发生了什么"，
  /// 完整日期在 `dump()` 的头部单独写一行。
  String get line {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return '$h:$m:$s $message';
  }
}

/// 运行日志的环形缓冲。
///
/// **为什么需要它**：`debugPrint` 只往 logcat 里写，用户在手机上完全看不见。
/// 2026-11-16 排查插件问题时，所有现场都只剩"点了没反应"这一句话 ——
/// WebView 的 JS 报错、离屏查询返回 unsupported、插件加载失败，全都沉在 logcat 里。
///
/// 设计上刻意保守：
/// - **只在内存**，不落盘、不上报（日志里有任务标题、插件 id，不该离开设备）。
/// - 固定条数上限，超了丢最旧的，不会因为日志把内存吃穿。
/// - 接管 `debugPrint` 而不是要求每处改调用点 —— 现有的 `[today]`、`[query-host]`
///   这类日志一行都不用动就自动进缓冲。
class AppLog {
  AppLog._();

  /// 800 条大约相当于一次完整启动 + 几轮插件操作。再多对"当场排查"没有帮助，
  /// 只会让复制出来的文本长到没法读。
  static const int maxEntries = 800;

  static final Queue<AppLogEntry> _entries = Queue<AppLogEntry>();

  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// 记一条。`tag` 不传时从消息开头的 `[xxx]` 推断。
  static void add(String message, {String? tag, DateTime? at}) {
    // 这里绝不能调 debugPrint：install() 之后它会回调 add，直接无限递归。
    try {
      _entries.addLast(AppLogEntry(
        at: at ?? DateTime.now(),
        tag: tag ?? _tagOf(message),
        message: message,
      ));
      while (_entries.length > maxEntries) {
        _entries.removeFirst();
      }
    } catch (_) {
      // 日志系统自身出问题不能影响业务，静默吞掉
    }
  }

  static String _tagOf(String message) {
    final open = message.indexOf('[');
    if (open < 0) return '';
    final close = message.indexOf(']', open);
    if (close < 0) return '';
    return message.substring(open + 1, close);
  }

  /// 全部条目（拷贝，调用方改不到内部）。
  static List<AppLogEntry> get entries => List<AppLogEntry>.of(_entries);

  static int get length => _entries.length;

  /// 按 tag 前缀过滤，返回**最近的** [limit] 条（时间正序）。
  ///
  /// 前缀匹配是因为 tag 有层级：`plugin` 能捞到 `plugin/plan_mode` 这类细分。
  static List<AppLogEntry> byTag(String tagPrefix, {int limit = 40}) {
    final hit = _entries.where((e) => e.tag.startsWith(tagPrefix)).toList();
    if (hit.length <= limit) return hit;
    return hit.sublist(hit.length - limit);
  }

  /// 同时匹配多个 tag 前缀，按时间合并后取最近 [limit] 条。
  static List<AppLogEntry> byTags(Iterable<String> tags, {int limit = 40}) {
    final prefixes = tags.toList();
    if (prefixes.isEmpty) return byTag('', limit: limit);
    final hit = _entries
        .where((e) => prefixes.any((p) => e.tag.startsWith(p)))
        .toList();
    if (hit.length <= limit) return hit;
    return hit.sublist(hit.length - limit);
  }

  static void clear() => _entries.clear();

  /// 整份日志的纯文本，用于复制。
  ///
  /// 头部带版本与条数：贴出来求助时，第一行就知道"是哪个版本、几条日志"。
  static String dump({String? header}) {
    final buffer = StringBuffer();
    if (header != null && header.isNotEmpty) {
      buffer.writeln(header);
    }
    buffer.writeln('日志 ${_entries.length} 条 / 上限 $maxEntries');
    for (final entry in _entries) {
      buffer.writeln(entry.line);
    }
    return buffer.toString();
  }

  /// 只给测试用：不装 `debugPrint` 也能重置状态。
  @visibleForTesting
  static void resetForTest() {
    _entries.clear();
    _installed = false;
  }
}
