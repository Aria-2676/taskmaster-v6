// 更新清单的守卫。
//
// 断言的不是"代码能跑"，而是几条**改坏了才会发现、且很难在 review 里看出来**
// 的纪律：
//   - 清单里的版本不能高于本地构建（否则指向一个还不存在的包，用户永远装不上）
//   - downloads 里只要有产物，就必须字段齐全（缺 sha256 等于不校验，比没有更糟）
//   - 清单必须能解析成客户端认识的版本号
//
// 发版时最容易犯的错是"先改清单、忘了传包"，这条测试就是拦它的。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/utils/version_utils.dart';

Map<String, Object?> _readJson(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path 不存在');
  final decoded = jsonDecode(file.readAsStringSync());
  expect(decoded, isA<Map>(), reason: '$path 顶层必须是对象');
  return Map<String, Object?>.from(decoded as Map);
}

/// `pubspec.yaml` 里的 `version: x.y.z+build`，只取前面的版本号。
String _pubspecVersion() {
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    if (!line.startsWith('version:')) continue;
    return line.substring('version:'.length).trim().split('+').first;
  }
  fail('pubspec.yaml 里没有 version 行');
}

void main() {
  late Map<String, Object?> manifest;
  late Map<String, Object?> latest;

  setUpAll(() {
    manifest = _readJson('update.json');
    latest = Map<String, Object?>.from(manifest['latest']! as Map);
  });

  test('清单里的版本必须能解析，且不能高于本地构建', () {
    final version = latest['version']! as String;
    expect(VersionUtils.isValid(version), isTrue, reason: '「$version」不是合法版本号');
    expect(
      VersionUtils.compare(version, _pubspecVersion()),
      lessThanOrEqualTo(0),
      reason: '发版顺序：先改 pubspec 构建、传包、最后才改清单。'
          '清单高过 pubspec 说明它指向一个还不存在的包。',
    );
  });

  test('minSupported 不能高于清单版本（那会让所有客户端都被判为过旧）', () {
    final minSupported = manifest['minSupported'];
    if (minSupported is! String || minSupported.isEmpty) return; // 允许留空 = 不强制
    expect(
      VersionUtils.compare(minSupported, latest['version']! as String),
      lessThanOrEqualTo(0),
    );
  });

  test('downloads 里只要有产物，就必须带 url + 64 位 sha256 + sizeBytes', () {
    final downloads = (latest['downloads'] as Map?) ?? const {};
    for (final entry in downloads.entries) {
      final target = Map<String, Object?>.from(entry.value as Map);
      final url = target['url'];
      expect(url, isA<String>(), reason: '${entry.key} 缺 url');
      expect(url as String, startsWith('http'), reason: '${entry.key} 的 url 不是 http(s)');
      expect(target['sha256'], isA<String>(), reason: '${entry.key} 缺 sha256');
      expect((target['sha256']! as String).length, 64,
          reason: '${entry.key} 的 sha256 不是 64 位十六进制');
      expect(target['sizeBytes'], isA<int>(), reason: '${entry.key} 缺 sizeBytes');
    }
  });

  test('APK 不能走 jsDelivr（单文件 20MB 上限，必然 403）', () {
    final downloads = (latest['downloads'] as Map?) ?? const {};
    for (final entry in downloads.entries) {
      final target = Map<String, Object?>.from(entry.value as Map);
      final urls = <String>[
        if (target['url'] is String) target['url']! as String,
        for (final m in (target['mirrors'] as List?) ?? const [])
          if (m is String) m,
      ];
      for (final u in urls) {
        expect(u.contains('jsdelivr'), isFalse,
            reason: '${entry.key}: jsDelivr 对 >20MB 的文件返回 403，APK 必须走 GitHub Releases');
      }
    }
  });
}
