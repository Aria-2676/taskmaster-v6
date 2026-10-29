// "取最新"这条在更新器上的落点：清单里的 updatedAt 必须解析得对。
//
// 解析错了不会抛异常，只会让"并发取最新"退化成"随便取一个"—— 那种 bug
// 只在"某个 CDN 节点发了旧清单"时才现形，靠人工是测不出来的。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/updater/services/app_update_service.dart';

void main() {
  test('updatedAt 能解析成 UTC', () {
    final at = AppUpdateService.manifestFreshness(
      '{"schemaVersion":1,"updatedAt":"2026-10-28T10:00:00Z"}',
    );
    expect(at, DateTime.utc(2026, 10, 28, 10));
  });

  test('没有 updatedAt 的老清单：按最旧处理', () {
    final at = AppUpdateService.manifestFreshness('{"schemaVersion":1}');
    expect(at, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  });

  test('坏 JSON 不抛，也按最旧处理（交给后面的解析去报错）', () {
    final at = AppUpdateService.manifestFreshness('{ 这不是 JSON');
    expect(at.isBefore(DateTime.utc(2000)), isTrue);
  });

  test('旧清单不会赢过新清单', () {
    final oldOne = AppUpdateService.manifestFreshness(
      '{"schemaVersion":1,"updatedAt":"2026-10-27T00:00:00Z"}',
    );
    final newOne = AppUpdateService.manifestFreshness(
      '{"schemaVersion":1,"updatedAt":"2026-10-28T10:00:00Z"}',
    );
    expect(newOne.isAfter(oldOne), isTrue);
  });
}
