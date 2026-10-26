import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置索引 asset 可读且能解析', () async {
    final text = await rootBundle.loadString('assets/plugins/index.json');
    // ignore: avoid_print
    print('index.json 前 80 字：${text.substring(0, text.length.clamp(0, 80))}');

    final index = PluginIndex.parse(jsonDecode(text) as Map<String, Object?>);
    expect(index.plugins, hasLength(1));
    expect(index.plugins.single.id, 'demo_help');
  });

  test('内置 zip 的大小与 sha256 与索引一致', () async {
    final text = await rootBundle.loadString('assets/plugins/index.json');
    final index = PluginIndex.parse(jsonDecode(text) as Map<String, Object?>);
    final pkg = index.plugins.single.package;

    final data = await rootBundle.load(pkg.path);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    expect(bytes.length, pkg.sizeBytes, reason: '索引里的 sizeBytes 与包不一致');
    expect(sha256.convert(bytes).toString(), pkg.sha256, reason: '索引里的 sha256 与包不一致');
  });
}
