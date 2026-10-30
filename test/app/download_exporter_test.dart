// 「存到下载目录」这条桥。
//
// 只测 Dart 侧：参数传对了、原生返回的路径透出来了、原生不给路径时不能当成功。
// 真机上写没写进去，靠 adb 看 /sdcard/Download/任务管家 有没有文件。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/app/data/download_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('taskmaster/export');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.arguments['name'] == 'empty.zip') return '';
      return 'Download/任务管家/${call.arguments['name']}';
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('把路径和文件名传下去，并把原生返回的位置透出来', () async {
    final saved = await const DownloadExporter()
        .saveToDownloads(path: '/data/app/backups/a.zip', name: 'a.zip');

    expect(saved, 'Download/任务管家/a.zip');
    expect(calls.single.method, 'saveToDownloads');
    expect(calls.single.arguments['path'], '/data/app/backups/a.zip');
  });

  test('原生没给路径：抛异常，不能装作成功', () async {
    await expectLater(
      const DownloadExporter().saveToDownloads(path: '/x/empty.zip', name: 'empty.zip'),
      throwsA(isA<StateError>()),
    );
  });
}
