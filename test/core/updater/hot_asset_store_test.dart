import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:v5_app/core/updater/services/hot_asset_store.dart';

void main() {
  late Directory root;
  late HotAssetStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hot_asset_store_test');
    store = HotAssetStore().withRootForTest(root.path);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> writeFile(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  group('HotAssetStore 路径解析', () {
    test('应能读到存在的热更文件', () async {
      await writeFile('games/icons/2048.png', 'PNG');

      final resolved = await store.resolvePath('games/icons/2048.png');

      expect(resolved, isNotNull);
      expect(await File(resolved!).readAsString(), 'PNG');
    });

    test('文件不存在时返回 null', () async {
      expect(await store.resolvePath('games/icons/missing.png'), isNull);
    });

    test('根目录不存在时一律返回 null 而不抛异常', () async {
      final missing = HotAssetStore().withRootForTest(
        p.join(root.path, 'nope'),
      );

      expect(await missing.resolvePath('any.txt'), isNull);
      expect(await missing.has('any.txt'), isFalse);
      expect(await missing.readAsJson('any.json'), isNull);
    });

    test('拒绝路径穿越与绝对路径', () async {
      // 探针必须放在**真正会被解析到**的位置，否则断言永远成立、属于「巧合通过」。
      // 路径语义提醒：`a/../../x` 里第一个 `..` 被 `a` 抵消，第二个才真正上跳，
      // 所以它落在 root 的**上一级**。
      final escapeTarget = File(
        p.join(root.path, '..', 'hot_escape_probe.txt'),
      );
      await escapeTarget.writeAsString('SECRET');
      addTearDown(() async {
        if (await escapeTarget.exists()) await escapeTarget.delete();
      });
      expect(await escapeTarget.exists(), isTrue, reason: '探针要真的落盘');

      // 证据：不加防护时这两条路径解析到的正是探针。
      expect(
        p.normalize(p.join(root.path, 'a/../../hot_escape_probe.txt')),
        p.normalize(escapeTarget.path),
      );

      expect(await store.resolvePath('../hot_escape_probe.txt'), isNull);
      expect(await store.resolvePath('a/../../hot_escape_probe.txt'), isNull);
      expect(await store.resolvePath('/etc/passwd'), isNull);
      expect(await store.resolvePath('C:/windows/win.ini'), isNull);
      expect(await store.resolvePath(''), isNull);
    });

    test('反斜杠会被规范化为正斜杠', () async {
      await writeFile('games/icons/a.png', 'A');

      expect(await store.resolvePath(r'games\icons\a.png'), isNotNull);
    });
  });

  group('HotAssetStore 读取', () {
    test('readAsString 返回 UTF-8 内容', () async {
      await writeFile('theme.json', '{"seedColor":"#FF0000"}');

      expect(await store.readAsString('theme.json'), '{"seedColor":"#FF0000"}');
    });

    test('readAsBytes 返回原始字节', () async {
      await writeFile('bin.dat', 'abc');

      expect(await store.readAsBytes('bin.dat'), utf8.encode('abc'));
    });

    test('readAsJson 解析合法 JSON', () async {
      await writeFile('cfg.json', '{"a":1}');

      expect(await store.readAsJson('cfg.json'), {'a': 1});
    });

    test('readAsJson 遇到畸形 JSON 返回 null 而不抛异常', () async {
      await writeFile('bad.json', '{"a":');

      expect(await store.readAsJson('bad.json'), isNull);
    });
  });

  group('HotAssetStore 缓存', () {
    test('同路径只查盘一次：先记下「不存在」，新建文件后仍返回 null', () async {
      expect(await store.resolvePath('late.txt'), isNull);

      // 直接落盘，但不通知 store —— 旧结论应被缓存住。
      await writeFile('late.txt', 'now exists');
      expect(await store.resolvePath('late.txt'), isNull, reason: '缓存未失效');

      store.invalidate();
      expect(await store.resolvePath('late.txt'), isNotNull);
    });

    test('invalidate 清掉「已解析根目录」的结论', () async {
      final empty = HotAssetStore().withRootForTest(p.join(root.path, 'later'));
      expect(await empty.resolvePath('x.txt'), isNull);

      // 目录此刻才被创建，若根目录结论被缓存住就仍然查不到。
      await Directory(p.join(root.path, 'later')).create();
      await writeFile('later/x.txt', 'X');

      expect(await empty.resolvePath('x.txt'), isNull, reason: '根目录结论被缓存');

      empty.invalidate();
      expect(await empty.resolvePath('x.txt'), isNotNull);
    });
  });
}
