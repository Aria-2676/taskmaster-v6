// 运行日志缓冲：诊断面板和"复制日志"都靠它。
//
// 这层坏了不会崩，但会让"点了没反应"重新变回不可诊断 —— 所以至少要锁住
// 「丢掉最旧的而不是爆内存」「tag 能按前缀过滤」这两条。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/diagnostics/app_log.dart';

void main() {
  setUp(AppLog.resetForTest);
  tearDown(AppLog.resetForTest);

  group('记录', () {
    test('从消息开头的方括号里取出 tag', () {
      AppLog.add('[today] 加载计划块：plan_mode@2.0.6');
      expect(AppLog.entries.single.tag, 'today');
      expect(AppLog.entries.single.message, contains('plan_mode'));
    });

    test('没有方括号前缀时 tag 为空，不崩', () {
      AppLog.add('裸消息');
      expect(AppLog.entries.single.tag, '');
    });

    test('显式 tag 优先于推断', () {
      AppLog.add('[ignored] x', tag: 'explicit');
      expect(AppLog.entries.single.tag, 'explicit');
    });
  });

  group('环形缓冲', () {
    test('超过上限时丢最旧的', () {
      for (var i = 0; i < AppLog.maxEntries + 5; i++) {
        AppLog.add('第 $i 条');
      }
      expect(AppLog.length, AppLog.maxEntries);
      // 最旧的那 5 条应该没了
      expect(AppLog.entries.first.message, '第 5 条');
      expect(AppLog.entries.last.message, '第 ${AppLog.maxEntries + 4} 条');
    });
  });

  group('过滤', () {
    test('按 tag 前缀匹配', () {
      AppLog.add('[plugin] 打开失败');
      AppLog.add('[plugin/plan_mode] 加载超时');
      AppLog.add('[today] 无关');
      final hit = AppLog.byTag('plugin');
      expect(hit.map((e) => e.tag), <String>['plugin', 'plugin/plan_mode']);
    });

    test('limit 取最近的 N 条，顺序仍是时间正序', () {
      for (var i = 0; i < 10; i++) {
        AppLog.add('[q] $i');
      }
      final hit = AppLog.byTag('q', limit: 3);
      expect(hit.map((e) => e.message), <String>['[q] 7', '[q] 8', '[q] 9']);
    });

    test('多前缀合并', () {
      AppLog.add('[a] 1');
      AppLog.add('[b] 2');
      AppLog.add('[c] 3');
      final hit = AppLog.byTags(<String>['a', 'c']);
      expect(hit.map((e) => e.tag), <String>['a', 'c']);
    });
  });

  group('导出', () {
    test('dump 带头部、条数和每行时间', () {
      AppLog.add('x', at: DateTime(2026, 11, 17, 14, 3, 27));
      final text = AppLog.dump(header: 'TaskMaster 6.1.11');
      expect(text, contains('TaskMaster 6.1.11'));
      expect(text, contains('日志 1 条'));
      expect(text, contains('14:03:27 x'));
    });

    test('clear 之后一条都不剩', () {
      AppLog.add('a');
      AppLog.clear();
      expect(AppLog.length, 0);
      expect(AppLog.dump(), contains('日志 0 条'));
    });
  });
}
