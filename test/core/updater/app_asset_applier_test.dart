import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:v5_app/core/updater/models/app_update_manifest.dart';
import 'package:v5_app/core/updater/services/app_asset_applier.dart';
import 'package:v5_app/core/updater/services/app_update_exception.dart';

List<int> buildZip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

/// 让 `new HttpClient()` 造出**真实**客户端的覆盖层。
///
/// [TestWidgetsFlutterBinding] 会把 `HttpOverrides.global` 换成它的假客户端，
/// 让所有请求一律返回 **HTTP 400**，目的是防止单测偷偷联网。但本文件用
/// [HttpServer] 起了一个本地回环服务，必须打到真实网络，否则：
/// - 期望成功的用例会拿到 400 而抛异常；
/// - 期望失败的用例虽然「恰好」通过，却是因为 400 而不是我们想测的原因——
///   断言形同虚设。
///
/// 因此联网用例必须包在 [HttpOverrides.runZoned] 里逃出这层覆盖。
/// 注意 `createHttpClient` 里**不能**直接写 `HttpClient()`——那会再次进入
/// 覆盖逻辑造成无限递归（Stack Overflow）；必须用 `super.createHttpClient`。
class _RealHttpOverrides extends HttpOverrides {
}

/// 在「真实网络」的 Zone 里跑 [body]，绕开测试绑定注入的 400 假客户端。
///
/// [HttpOverrides.runZoned] 的 `body` 是同步签名、返回 `R`；这里让 `R = Future<T>`，
/// 因此能直接 await 结果，也让 Zone 覆盖在整个异步流程期间都有效。
Future<T> withRealHttp<T>(Future<T> Function() body) {
  return HttpOverrides.runZoned<Future<T>>(
    body,
    createHttpClient: (context) => _RealHttpOverrides().createHttpClient(context),
  );
}

/// 极简静态文件服务，用于给 applier 喂真实的、可校验的 zip。
class _ZipServer {
  _ZipServer(this._server) {
    _server.listen((request) async {
      final body = _routes[request.uri.path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
  }

  final HttpServer _server;
  final Map<String, List<int>> _routes = {};

  Uri serve(String path, List<int> bytes) {
    _routes['/$path'] = bytes;
    return Uri.parse('http://127.0.0.1:${_server.port}/$path');
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  // path_provider 走 MethodChannel；下面的用例会真的调用它，
  // 因此必须先初始化绑定，否则 ServicesBinding.instance 不可用。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late _ZipServer server;
  late String root;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('v5_asset_test');
    root = p.join(sandbox.path, 'hot_assets');
    server = _ZipServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  });

  tearDown(() async {
    await server.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  /// 造一个可用的资源包并登记到本地服务，返回 (包描述, sha256)。
  (AssetUpdatePackage, String) makePackage(
    Map<String, List<int>> entries, {
    int build = 1,
    String path = 'assets.zip',
  }) {
    final bytes = buildZip(entries);
    final uri = server.serve(path, bytes);
    final sha = sha256.convert(bytes).toString();
    return (
      AssetUpdatePackage(
        build: build,
        url: uri.toString(),
        sha256: sha,
        sizeBytes: bytes.length,
      ),
      sha,
    );
  }

  group('AppAssetApplier', () {
    // 下面所有「真的要联网」的用例都包在 withRealHttp 里：
    // 测试绑定默认让 HttpClient 返回 400，不逃出去就测不到真实下载路径。
    test('首次应用：下载 → 校验 → 解压到目标根目录', () => withRealHttp(() async {
          final (pkg, _) = makePackage({
            'ui/theme.json': utf8.encode('{"dark":true}'),
            'ui/strings.json': utf8.encode('{"hi":"你好"}'),
          });
          final applier = AppAssetApplier(rootDir: root);

          expect(await applier.apply(pkg), isTrue);
          expect(await File(p.join(root, 'ui', 'theme.json')).readAsString(),
              '{"dark":true}');
          expect(await File(p.join(root, 'ui', 'strings.json')).exists(), isTrue);
        }));

    test('sha256 不符：抛异常且不落位', () => withRealHttp(() async {
          final bytes = buildZip({'a.txt': utf8.encode('x')});
          final uri = server.serve('bad.zip', bytes);
          final pkg = AssetUpdatePackage(
            build: 1,
            url: uri.toString(),
            sha256: 'deadbeef' * 8, // 故意错的摘要
            sizeBytes: bytes.length,
          );

          await expectLater(
            AppAssetApplier(rootDir: root).apply(pkg),
            throwsA(isA<AppUpdateException>()),
          );
          expect(await Directory(root).exists(), isFalse);
        }));

    test('大小不符：抛异常且不落位', () => withRealHttp(() async {
          final (pkg, _) = makePackage({'a.txt': utf8.encode('x')});
          final wrong = AssetUpdatePackage(
            build: pkg.build,
            url: pkg.url,
            sha256: pkg.sha256,
            sizeBytes: pkg.sizeBytes + 999,
          );

          await expectLater(
            AppAssetApplier(rootDir: root).apply(wrong),
            throwsA(isA<AppUpdateException>()),
          );
          expect(await Directory(root).exists(), isFalse);
        }));

    test('畸形包（含 .. 条目）：抛异常，且已有资源完好', () => withRealHttp(() async {
          // 先放一份「旧资源」
          await Directory(root).create(recursive: true);
          await File(p.join(root, 'keep.txt')).writeAsString('old');

          final (pkg, _) = makePackage(
            {'../escape.txt': utf8.encode('pwn')},
            path: 'evil.zip',
          );

          await expectLater(
            AppAssetApplier(rootDir: root).apply(pkg),
            throwsA(isA<AppUpdateException>()),
          );
          // 关键：旧资源不能被破坏，越界文件不能出现
          expect(await File(p.join(root, 'keep.txt')).readAsString(), 'old');
          expect(await File(p.join(sandbox.path, 'escape.txt')).exists(), isFalse);
        }));

    test('升级替换：新内容生效，旧文件不残留', () => withRealHttp(() async {
          final applier = AppAssetApplier(rootDir: root);

          final (v1, _) = makePackage(
            {'a.txt': utf8.encode('v1'), 'obsolete.txt': utf8.encode('bye')},
            build: 1,
            path: 'v1.zip',
          );
          await applier.apply(v1);
          expect(await File(p.join(root, 'obsolete.txt')).exists(), isTrue);

          final (v2, _) = makePackage(
            {'a.txt': utf8.encode('v2')},
            build: 2,
            path: 'v2.zip',
          );
          await applier.apply(v2);

          expect(await File(p.join(root, 'a.txt')).readAsString(), 'v2');
          // 替换是整目录换新，旧包独有的文件必须消失
          expect(await File(p.join(root, 'obsolete.txt')).exists(), isFalse);
        }));

    test('替换成功后不留 .bak 备份目录', () => withRealHttp(() async {
          final applier = AppAssetApplier(rootDir: root);
          final (v1, _) = makePackage({'a.txt': utf8.encode('1')},
              build: 1, path: 'b1.zip');
          await applier.apply(v1);
          final (v2, _) = makePackage({'a.txt': utf8.encode('2')},
              build: 2, path: 'b2.zip');
          await applier.apply(v2);

          final leftovers = await Directory(sandbox.path)
              .list()
              .where((e) => e.path.contains('.bak-'))
              .toList();
          expect(leftovers, isEmpty);
        }));

    // 地址非法不联网，无需逃逸。
    test('地址非法：抛异常', () async {
      const pkg = AssetUpdatePackage(build: 1, url: '::::not a uri');
      await expectLater(
        AppAssetApplier(rootDir: root).apply(pkg),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('404：抛异常且不落位', () => withRealHttp(() async {
          final pkg = AssetUpdatePackage(
            build: 1,
            url: 'http://127.0.0.1:${server._server.port}/missing.zip',
            sha256: '',
          );

          await expectLater(
            AppAssetApplier(rootDir: root).apply(pkg),
            throwsA(isA<AppUpdateException>()),
          );
          expect(await Directory(root).exists(), isFalse);
        }));

    test('resolveRoot 未注入时回落到应用支持目录', () async {
      // path_provider 通过 MethodChannel 与宿主通信，测试里没有宿主，
      // 因此显式给出一个假的通道实现。
      //
      // ⚠️ 通道方法名与 Dart 侧方法名**不一样**，这是极易踩的坑：
      //   Dart 层 getApplicationSupportPath() → 通道里发 'getApplicationSupportDirectory'
      //   Dart 层 getTemporaryPath()          → 通道里发 'getTemporaryDirectory'
      // （见 path_provider_platform_interface 的 MethodChannelPathProvider）
      // 按 Dart 方法名 mock 永远不会被命中，handler 返回 null，
      // path_provider 随即抛 MissingPlatformDirectoryException。
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') return sandbox.path;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const applier = AppAssetApplier();
      final resolved = await applier.resolveRoot();
      expect(resolved, p.join(sandbox.path, 'hot_assets'));
    });

    test('平台通道不可用时 apply 抛 AppUpdateException 而不是 FlutterError', () async {
      // 只注入 workDir，让 resolveRoot 走真实平台通道。
      // 这里没有注册通道实现，path_provider 会失败：
      // 路径解析若在 try 之外，调用方拿到的是 FlutterError；
      // 这正是本次修复要覆盖的回归点。
      final (pkg, _) = makePackage({'a.txt': utf8.encode('x')});

      await expectLater(
        AppAssetApplier(workDir: sandbox.path).apply(pkg),
        throwsA(isA<AppUpdateException>()),
      );
    });
  });
}
