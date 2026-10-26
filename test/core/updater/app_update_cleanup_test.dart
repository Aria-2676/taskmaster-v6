import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:v5_app/core/updater/services/app_update_launcher.dart';

/// 覆盖 [AppUpdateLauncher.cleanupStaleFiles]：
/// 成功安装后不能立刻删 APK，只能靠启动时按「超过阈值」回收。
void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('v5_cleanup_test');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  /// 构造「[age] 之前」的毫秒时间戳，与真实命名 `update-<ms>-0.apk` 一致。
  String stampAgo(Duration age) =>
      DateTime.now().subtract(age).millisecondsSinceEpoch.toString();

  Future<void> callCleanup() =>
      AppUpdateLauncher.cleanupStaleFiles(tempDirProvider: () async => sandbox);

  test('清理超过阈值的旧包，保留刚下载的与无关文件', () async {
    final old = Duration(hours: 7);
    final staleApk =
        File(p.join(sandbox.path, 'update-${stampAgo(old)}-0.apk'));
    final staleZip = File(p.join(sandbox.path, 'asset-${stampAgo(old)}.zip'));
    final staleStage =
        Directory(p.join(sandbox.path, 'asset-stage-${stampAgo(old)}'));
    final freshApk = File(
      p.join(sandbox.path, 'update-${stampAgo(Duration.zero)}-0.apk'),
    );
    final foreign = File(p.join(sandbox.path, 'other-module.dat'));

    await staleApk.writeAsBytes(const [1]);
    await staleZip.writeAsBytes(const [1]);
    await staleStage.create(recursive: true);
    await File(p.join(staleStage.path, 'inner.bin')).writeAsBytes(const [1]);
    await freshApk.writeAsBytes(const [1]);
    await foreign.writeAsBytes(const [1]);

    await callCleanup();

    expect(await staleApk.exists(), isFalse);
    expect(await staleZip.exists(), isFalse);
    expect(await staleStage.exists(), isFalse);
    // 正在下载 / 用户还没点安装的那份必须留着。
    expect(await freshApk.exists(), isTrue);
    // 前缀不属于本模块的文件不能动。
    expect(await foreign.exists(), isTrue);
  });

  test('阈值内的新包一律不删（哪怕前缀命中）', () async {
    final apk = File(
      p.join(sandbox.path, 'update-${stampAgo(const Duration(minutes: 5))}-0.apk'),
    );
    await apk.writeAsBytes(const [1]);

    await callCleanup();

    expect(await apk.exists(), isTrue);
  });

  test('解析不出时间戳的文件不清理（避免误删同目录其他文件）', () async {
    final odd = File(p.join(sandbox.path, 'update-broken.apk'));
    await odd.writeAsBytes(const [1]);

    await callCleanup();

    expect(await odd.exists(), isTrue);
  });

  test('目录不存在时安静返回，不抛异常', () async {
    await AppUpdateLauncher.cleanupStaleFiles(
      tempDirProvider: () async => Directory(p.join(sandbox.path, 'nope')),
    );
  });
}
