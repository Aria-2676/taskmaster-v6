import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:v5_app/core/services/file_downloader.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('v5_dl_test');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  String path(String name) => p.join(sandbox.path, name);

  /// 启动一个本机 HTTP 服务，[handler] 决定如何应答。
  /// 返回 (server, url)。
  Future<(HttpServer, Uri)> startServer(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    final url = Uri.parse('http://127.0.0.1:${server.port}/file');
    return (server, url);
  }

  group('FileDownloader.download', () {
    test('完整下载：进度回调递增、total 正确、内容一致', () async {
      final payload = utf8.encode('hello v5 downloader');
      final (server, url) = await startServer((request) {
        request.response
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final progress = <(int, int?)>[];
      final dest = path('ok.bin');
      await FileDownloader.download(
        url: url,
        destPath: dest,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(await File(dest).readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, (payload.length, payload.length));
      // total 全程已知（服务端给了 Content-Length）
      for (final (_, total) in progress) {
        expect(total, payload.length);
      }
    });

    test('HTTP 错误状态抛 FileDownloadException，且不创建半截文件', () async {
      final (server, url) = await startServer((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final dest = path('not_found.bin');
      await expectLater(
        FileDownloader.download(url: url, destPath: dest),
        throwsA(
          isA<FileDownloadException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
      // 状态检查在打开写入流之前，目标文件不应被创建
      expect(await File(dest).exists(), isFalse);
    });

    test('取消：isCancelled 为 true 时必须中止，不得静默成功', () async {
      final payload = List<int>.filled(128, 1);
      final (server, url) = await startServer((request) {
        request.response
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        FileDownloader.download(
          url: url,
          destPath: path('cancelled.bin'),
          isCancelled: () => true,
        ),
        throwsA(
          isA<FileDownloadException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
    });

    test('服务端声明 Content-Length 但提前关连接：必须失败而非静默成功', () async {
      // 用裸 TCP 服务精确控制字节流：声明 100 字节，只发 50 就 FIN。
      // 不同网络栈表现不一（dart:io 多半自己抛 HttpException，被包成
      // FileDownloadException；个别栈不抛则落到下载器的 Content-Length 核对），
      // 契约只有一个：绝不把半个文件当成功返回。
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      server.listen((socket) async {
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 100\r\n'
          'Connection: close\r\n'
          '\r\n',
        );
        socket.add(List<int>.filled(50, 7));
        await socket.flush();
        await socket.close();
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/file');

      await expectLater(
        FileDownloader.download(url: url, destPath: path('truncated.bin')),
        throwsA(isA<FileDownloadException>()),
      );
    });

    test('未知长度（chunked）也能下载成功，total 为 null', () async {
      final payload = utf8.encode('chunked body');
      final (server, url) = await startServer((request) {
        // 不设 contentLength → chunked，客户端拿到 -1 → total 为 null
        request.response
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final progress = <(int, int?)>[];
      final dest = path('chunked.bin');
      await FileDownloader.download(
        url: url,
        destPath: dest,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(await File(dest).readAsBytes(), payload);
      expect(progress.last.$1, payload.length);
      expect(progress.last.$2, isNull);
    });

    test('allowResume=true：服务端支持 Range 时只补剩余字节，进度从残包接着走',
        () async {
      final payload = utf8.encode('0123456789abcdefghij');
      const half = 8;
      final ranges = <String>[];
      final (server, url) = await startServer((request) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range == null) {
          request.response
            ..contentLength = payload.length
            ..add(payload)
            ..close();
          return;
        }
        ranges.add(range);
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
        );
        final body = payload.sublist(start);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = body.length
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}',
          )
          ..add(body)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final dest = path('resume.bin');
      await File(dest).writeAsBytes(payload.sublist(0, half));

      final progress = <(int, int?)>[];
      await FileDownloader.download(
        url: url,
        destPath: dest,
        allowResume: true,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(await File(dest).readAsBytes(), payload);
      expect(ranges, ['bytes=$half-']);
      // total 按「残包 + 剩余」合计，最后一帧等于整包大小。
      expect(progress.last, (payload.length, payload.length));
    });

    test('allowResume=true：服务端忽略 Range（回 200 整包）时自动整包重下，不污染内容',
        () async {
      final payload = utf8.encode('full body without range support');
      final (server, url) = await startServer((request) {
        // 无视 Range，永远回整包。
        request.response
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final dest = path('ignore_range.bin');
      // 脏残包：若不从头覆盖，追加模式会把它拼到正确内容前面。
      await File(dest).writeAsBytes(List<int>.filled(payload.length ~/ 2, 0xEE));

      await FileDownloader.download(url: url, destPath: dest, allowResume: true);
      expect(await File(dest).readAsBytes(), payload);
    });

    test('allowResume=true：残包超过源大小（416）时删残包整包重下', () async {
      final payload = utf8.encode('short');
      final (server, url) = await startServer((request) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..close();
          return;
        }
        request.response
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final dest = path('range_416.bin');
      await File(dest).writeAsBytes(List<int>.filled(999, 5));

      await FileDownloader.download(url: url, destPath: dest, allowResume: true);
      expect(await File(dest).readAsBytes(), payload);
    });

    test('allowResume 默认关闭：即使同名文件已存在也不发 Range，直接覆盖', () async {
      final payload = utf8.encode('overwrite me');
      final ranges = <String>[];
      final (server, url) = await startServer((request) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) ranges.add(range);
        request.response
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });
      addTearDown(() => server.close(force: true));

      final dest = path('overwrite.bin');
      await File(dest).writeAsBytes(List<int>.filled(3, 0));

      await FileDownloader.download(url: url, destPath: dest);

      expect(ranges, isEmpty);
      expect(await File(dest).readAsBytes(), payload);
    });

    test('网络异常保留原始 SocketException（cause），供上层判定可重试', () async {
      // 绑定后立即释放端口 → 拿到一个必然拒绝连接的地址。
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      await expectLater(
        FileDownloader.download(
          url: Uri.parse('http://127.0.0.1:$port/file'),
          destPath: path('refused.bin'),
          connectTimeout: const Duration(seconds: 2),
        ),
        throwsA(
          isA<FileDownloadException>().having(
            (e) => e.cause,
            'cause',
            isA<SocketException>(),
          ),
        ),
      );
    });
  });

  group('FileDownloader sha256 校验', () {
    test('sha256OfFile 与 crypto 包计算一致', () async {
      final data = utf8.encode('digest me');
      final file = path('digest.bin');
      await File(file).writeAsBytes(data);

      expect(
        await FileDownloader.sha256OfFile(file),
        sha256.convert(data).toString(),
      );
    });

    test('verifySha256：摘要一致（含大写）通过，不一致拒绝', () async {
      final data = utf8.encode('abc');
      final file = path('verify.bin');
      await File(file).writeAsBytes(data);
      final digest = sha256.convert(data).toString();

      expect(await FileDownloader.verifySha256(file, digest), isTrue);
      expect(
        await FileDownloader.verifySha256(file, digest.toUpperCase()),
        isTrue,
      );
      expect(
        await FileDownloader.verifySha256(file, '0' * 64),
        isFalse,
      );
    });

    test('verifySha256：清单未给摘要时放行（降级由调用方决定）', () async {
      final file = path('no_digest.bin');
      await File(file).writeAsBytes([1, 2, 3]);
      expect(await FileDownloader.verifySha256(file, ''), isTrue);
    });
  });
}
