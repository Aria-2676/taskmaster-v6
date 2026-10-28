import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';

/// 内置索引与包的一致性。
///
/// 这里**遍历所有插件**而不是断言"只有 demo_help"：后者会让每加一个插件
/// 就得改一次测试，而测试一改就失去"它是守卫"的意义 —— 久而久之就没人看它了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PluginIndex> loadIndex() async {
    final text = await rootBundle.loadString('assets/plugins/index.json');
    return PluginIndex.parse(jsonDecode(text) as Map<String, Object?>);
  }

  test('内置索引可读、能解析、至少有一个插件', () async {
    final index = await loadIndex();
    expect(index.plugins, isNotEmpty);
    expect(index.plugins.map((p) => p.id), contains('demo_help'));
    // 插件 id 会成为目录名与表前缀，格式必须在入口就挡住
    for (final entry in index.plugins) {
      expect(RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(entry.id), isTrue,
          reason: '插件 id 非法：${entry.id}');
    }
  });

  test('每个内置 zip 的大小与 sha256 都与索引一致', () async {
    final index = await loadIndex();
    for (final entry in index.plugins) {
      final pkg = entry.package;
      final data = await rootBundle.load(pkg.path);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      expect(bytes.length, pkg.sizeBytes,
          reason: '${entry.id}: 索引里的 sizeBytes 与包不一致（重新跑 make_demo_plugin.py）');
      expect(sha256.convert(bytes).toString(), pkg.sha256,
          reason: '${entry.id}: 索引里的 sha256 与包不一致（重新跑 make_demo_plugin.py）');
    }
  });

  test('索引里的权限声明与包内 plugin.json 一致', () async {
    final index = await loadIndex();
    for (final entry in index.plugins) {
      // 权限必须在下载**之前**就能告知用户，所以索引里带了一份；
      // 但权威来源是包内的 plugin.json —— 两者不一致时用户会看到假话。
      // plugins_src 不打进包（只有打包脚本用），所以这里读磁盘而不是 asset
      final manifest = jsonDecode(
        File('assets/plugins_src/${entry.id}/plugin.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final declared = (manifest['permissions'] as List?)?.cast<String>() ?? const <String>[];

      expect(entry.permissions.toSet(), declared.toSet(),
          reason: '${entry.id}: 索引与 plugin.json 的权限对不上');
    }
  });

  test('内置插件页不写死自身版本，一律从 system.info 取', () async {
    // 守卫的是一个真发生过的 bug：`energy_currency` 页面里写着
    // `契约 1 · v1.0.0`，升级到 1.1.0 之后页面还挂着旧版本号。
    // 版本只能由宿主（包内 plugin.json）给，页面自己不许存。
    final index = await loadIndex();

    for (final entry in index.plugins) {
      final data = await rootBundle.load(entry.package.path);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final archive = ZipDecoder().decodeBytes(bytes);

      final page = archive.findFile('index.html');
      expect(page, isNotNull, reason: '${entry.id}: 包里没有 index.html');
      final html = utf8.decode(page!.content);

      expect(html.contains('v${entry.version}'), isFalse,
          reason: '${entry.id}: 页面里把版本 v${entry.version} 写死了，升级后不会跟着变');
      expect(html.contains('system.info'), isTrue,
          reason: '${entry.id}: 页面没有通过 system.info 读版本；升级后显示的会是旧版本号');
    }
  });
}
