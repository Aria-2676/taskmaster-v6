import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/updater/services/app_update_exception.dart';
import 'package:v5_app/core/updater/services/app_update_service.dart';

/// 一份最小合法清单。
const String _manifestBody = '''
{
  "schemaVersion": 1,
  "updatedAt": "2026-10-15T00:00:00Z",
  "latest": {
    "version": "6.0.0",
    "downloads": {
      "android": { "url": "https://example.com/app.apk" }
    }
  }
}
''';

Future<(HttpServer, Uri)> startServer(
  FutureOr<void> Function(HttpRequest request) handler, {
  String path = '/update.json',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return (server, Uri.parse('http://127.0.0.1:${server.port}$path'));
}

void main() {
  group('AppUpdateService.fetchManifest 多源回退', () {
    test('首个候选即成功：解析清单且请求带 no-cache', () async {
      String? userAgent;
      final seenCacheControl = <bool>[];
      final (server, url) = await startServer((request) {
        userAgent = request.headers.value('user-agent');
        seenCacheControl.add(
          request.headers.value(HttpHeaders.cacheControlHeader) == 'no-cache',
        );
        request.response
          ..headers.contentType = ContentType.json
          ..write(_manifestBody)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final service = AppUpdateService(
        candidateProvider: () => [url],
        contentsApiUrl: Uri.parse('http://127.0.0.1:1/unreachable'),
      );
      final manifest = await service.fetchManifest();

      expect(manifest.release?.version, '6.0.0');
      expect(seenCacheControl, [true]);
      // dart:io 默认会带 Dart 的 UA，这里只确认请求头机制没被破坏。
      expect(userAgent, isNotNull);
    });

    test('首个候选 500、第二个成功时整体仍成功', () async {
      final (bad, badUrl) = await startServer((request) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      });
      final (good, goodUrl) = await startServer((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(_manifestBody)
          ..close();
      });
      addTearDown(() => bad.close(force: true));
      addTearDown(() => good.close(force: true));

      final service = AppUpdateService(
        candidateProvider: () => [badUrl, goodUrl],
        contentsApiUrl: Uri.parse('http://127.0.0.1:1/unreachable'),
      );
      final manifest = await service.fetchManifest();
      expect(manifest.release?.version, '6.0.0');
    });

    test('普通候选全部失败时，回退 Contents API 的 base64 信封', () async {
      final (dead, deadUrl) = await startServer((request) {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..close();
      });
      addTearDown(() => dead.close(force: true));

      // GitHub Contents API 把 base64 内容按 76 列折行。手工折行构造，
      // 不依赖不同 SDK 版本 base64.encode 是否自带换行——客户端必须
      // 能剥掉任意空白再解码。
      final flat = base64.encode(utf8.encode(_manifestBody));
      final lines = <String>[];
      for (var i = 0; i < flat.length; i += 76) {
        lines.add(
          flat.substring(i, (i + 76).clamp(0, flat.length)),
        );
      }
      expect(lines.length, greaterThan(1));
      final wrapped = lines.join('\n');
      final envelope = jsonEncode({
        'encoding': 'base64',
        'content': wrapped,
      });

      var acceptSeen = '';
      final (api, apiUrl) = await startServer(
        (request) {
          acceptSeen = request.headers.value('accept') ?? '';
          request.response
            ..headers.contentType = ContentType.json
            ..write(envelope)
            ..close();
        },
        path: '/repos/o/r/contents/update.json',
      );
      addTearDown(() => api.close(force: true));

      final service = AppUpdateService(
        candidateProvider: () => [deadUrl],
        contentsApiUrl: apiUrl,
      );
      final manifest = await service.fetchManifest();
      expect(manifest.release?.version, '6.0.0');
      // 必须显式请求 GitHub JSON 媒体类型，否则 Contents API 默认也给 JSON，
      // 但带上版本化媒体类型是文档约定。
      expect(acceptSeen, contains('github'));
    });

    test('Contents 信封结构异常时抛 AppUpdateException', () async {
      final (dead, deadUrl) = await startServer((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      });
      addTearDown(() => dead.close(force: true));

      final (api, apiUrl) = await startServer(
        (request) {
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'encoding': 'base64'})) // 缺 content
            ..close();
        },
        path: '/bad-envelope',
      );
      addTearDown(() => api.close(force: true));

      final service = AppUpdateService(
        candidateProvider: () => [deadUrl],
        contentsApiUrl: apiUrl,
      );
      await expectLater(
        service.fetchManifest(),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('所有源均失败时抛 AppUpdateException', () async {
      final (dead, deadUrl) = await startServer((request) {
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..close();
      });
      addTearDown(() => dead.close(force: true));

      final service = AppUpdateService(
        candidateProvider: () => [deadUrl],
        contentsApiUrl: Uri.parse('http://127.0.0.1:1/unreachable'),
        timeout: const Duration(seconds: 2),
      );
      await expectLater(
        service.fetchManifest(),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('tryFetchManifest 在全失败时返回 null 而不抛错', () async {
      final service = AppUpdateService(
        candidateProvider: () => [Uri.parse('http://127.0.0.1:1/nope')],
        contentsApiUrl: Uri.parse('http://127.0.0.1:1/nope-api'),
        timeout: const Duration(seconds: 1),
      );
      expect(await service.tryFetchManifest(), isNull);
    });
  });
}
