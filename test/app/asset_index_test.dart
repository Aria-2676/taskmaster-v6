import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';

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

  /// 包里那份文件从哪儿读：随包的从 asset，仓库分发的从磁盘。
  ///
  /// 两个用例都要它 —— 以后加一个"只从仓库分发"的插件，别让某一条测试
  /// 还傻等着 rootBundle 里有一份。
  Future<Uint8List> bytesOf(PluginPackage pkg) async {
    if (pkg.path.startsWith('assets/')) {
      final data = await rootBundle.load(pkg.path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final file = File(pkg.path);
    expect(file.existsSync(), isTrue,
        reason: '索引指向 ${pkg.path}，但仓库里没有这个文件（线上会 404）');
    return file.readAsBytesSync();
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

  test('每个包的体积与 sha256 都与索引一致（随包的读 asset，仓库分发的读磁盘）', () async {
    // 包的**路径**就是分发方式：
    //   assets/plugins/…     打进 APK，断网也能装（离线兜底）
    //   plugins/packages/…   只从仓库分发，装的时候联网下载
    // 两种都要在这里守住 —— 前者漏打包 = 断网装不上；后者漏提交 = 线上 404。
    final index = await loadIndex();
    for (final entry in index.plugins) {
      final pkg = entry.package;
      final bytes = await bytesOf(pkg);

      if (!pkg.path.startsWith('assets/')) {
        // 同一个包两边都有 = 打包脚本没清旧的。这会让"仓库分发"名不副实：
        // APK 里还悄悄躺着那份，用户以为自己下的是新的。
        final stray = File(p.join('assets', 'plugins', p.basename(pkg.path)));
        expect(stray.existsSync(), isFalse,
            reason: '${entry.id}: 同一个包在 assets/ 和 plugins/packages/ 各有一份，重新跑 make_demo_plugin.py');
      }

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
      // 插件源码不打进包（只有打包脚本用），所以这里读磁盘而不是 asset
      final manifest = jsonDecode(
        File('plugins/src/${entry.id}/plugin.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final declared = (manifest['permissions'] as List?)?.cast<String>() ?? const <String>[];

      expect(entry.permissions.toSet(), declared.toSet(),
          reason: '${entry.id}: 索引与 plugin.json 的权限对不上');
    }
  });

  test('索引里的 home 声明与包内 plugin.json 一致', () async {
    // 索引里那份由打包脚本从 plugin.json 复制。对不上的后果不是"难看"：
    // 顶栏的快捷切换读的是索引 —— 模式名和默认开不开都会错。
    final index = await loadIndex();
    for (final entry in index.plugins) {
      final manifest = jsonDecode(
        File('plugins/src/${entry.id}/plugin.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final declared = PluginHomeSpec.tryParse(manifest['home']);

      expect(entry.home, declared,
          reason: '${entry.id}: 索引与 plugin.json 的 home 不一致');
    }
  });

  test('内置插件页不写死自身版本，一律从 system.info 取', () async {
    // 守卫的是一个真发生过的 bug：`energy_currency` 页面里写着
    // `契约 1 · v1.0.0`，升级到 1.1.0 之后页面还挂着旧版本号。
    // 版本只能由宿主（包内 plugin.json）给，页面自己不许存。
    final index = await loadIndex();

    for (final entry in index.plugins) {
      final archive = ZipDecoder().decodeBytes(await bytesOf(entry.package));

      final page = archive.findFile('index.html');
      expect(page, isNotNull, reason: '${entry.id}: 包里没有 index.html');
      final html = utf8.decode(page!.content);

      expect(html.contains('v${entry.version}'), isFalse,
          reason: '${entry.id}: 页面里把版本 v${entry.version} 写死了，升级后不会跟着变');

      // 只有**确实显示版本**的页面才必须走 system.info。
      // 原来是无条件要求，结果计划模式这种压根不显示版本的页面也被判失败 ——
      // 守卫要拦的是"写死版本号"，不是"每个页面都得报版本"。
      final showsVersion =
          RegExp(r'[vV]\d+\.\d+\.\d+').hasMatch(html);
      if (showsVersion) {
        expect(html.contains('system.info'), isTrue,
            reason: '${entry.id}: 页面显示了版本却没有通过 system.info 读，升级后会是旧号');
      }
    }
  });
}
