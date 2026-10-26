// 安装器测试：下载 → 校验 → 解压 → 落位 → 登记，以及卸载与启动自愈。
//
// 网络用注入的 fetcher 绕开（直接复制本地文件），这样"装不上"的各种原因
// 都能被稳定构造出来，不依赖外网。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';
import 'package:v5_app/core/plugin/plugin_installer.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
import 'package:v5_app/core/services/file_downloader.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tempRoot;
  late Directory pluginRoot;
  late Database db;
  late PluginInstaller installer;

  Future<void> fakeFetch({
    required Uri url,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) async {
    final source = File(url.toFilePath());
    await source.copy(destPath);
    onProgress?.call(await source.length(), await source.length());
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('v6_plugin_');
    pluginRoot = Directory(p.join(tempRoot.path, 'plugins'));
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    installer = PluginInstaller(
      db: db,
      rootDir: pluginRoot,
      schemas: PluginSchemaRegistry(),
      fetch: fakeFetch,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  /// 造一个真实 zip，返回它的路径与 sha256
  Future<({String path, String sha})> buildZip({
    String id = 'pomodoro',
    String version = '1.0.0',
    int contract = 1,
    bool includeManifest = true,
    bool includeEntry = true,
  }) async {
    final archive = Archive();
    if (includeManifest) {
      final manifest = utf8.encode(jsonEncode(<String, Object?>{
        'id': id,
        'name': '番茄钟',
        'version': version,
        'contract': contract,
        'entry': 'index.html',
      }));
      archive.addFile(ArchiveFile('plugin.json', manifest.length, manifest));
    }
    if (includeEntry) {
      final html = utf8.encode('<html><body>hi</body></html>');
      archive.addFile(ArchiveFile('index.html', html.length, html));
    }
    final data = ZipEncoder().encode(archive);
    final file = File(p.join(tempRoot.path, 'pkg_${id}_$version.zip'));
    await file.writeAsBytes(data);
    return (path: file.path, sha: await FileDownloader.sha256OfFile(file.path));
  }

  PluginIndexEntry entryFor({
    String id = 'pomodoro',
    String version = '1.0.0',
    int contract = 1,
    required String sha,
  }) =>
      PluginIndexEntry(
        id: id,
        name: '番茄钟',
        version: version,
        contract: contract,
        package: PluginPackage(path: 'plugins/a.zip', sha256: sha, sizeBytes: 100),
      );

  test('正常安装：文件落位 + 登记，工作区被清空', () async {
    final zip = await buildZip();
    final entry = entryFor(sha: zip.sha);

    final installed = await installer.install(
      entry,
      packageUrl: Uri.file(zip.path),
    );

    expect(installed.pluginId, 'pomodoro');
    expect(installed.installDir, 'pomodoro/1.0.0');

    final entryFile = File(p.join(pluginRoot.path, 'pomodoro', '1.0.0', 'index.html'));
    expect(await entryFile.exists(), isTrue, reason: '入口文件应该解压到位');

    expect(await installer.store.find('pomodoro'), isNotNull);
    expect(await Directory(p.join(pluginRoot.path, '.tmp')).exists(), isFalse,
        reason: '工作区应该被清掉');
  });

  test('sha256 不匹配：不落位、不登记', () async {
    final zip = await buildZip();
    final entry = entryFor(sha: 'b' * 64);

    await expectLater(
      installer.install(entry, packageUrl: Uri.file(zip.path)),
      throwsA(isA<PluginInstallException>()),
    );

    expect(await installer.store.find('pomodoro'), isNull);
    expect(await Directory(p.join(pluginRoot.path, 'pomodoro')).exists(), isFalse);
  });

  test('包内 id 与索引不一致：拒绝安装', () async {
    final zip = await buildZip(id: 'other');
    final entry = entryFor(id: 'pomodoro', sha: zip.sha);

    await expectLater(
      installer.install(entry, packageUrl: Uri.file(zip.path)),
      throwsA(isA<PluginInstallException>()),
    );
    expect(await installer.store.find('pomodoro'), isNull);
    expect(await installer.store.find('other'), isNull);
  });

  test('包内缺 plugin.json：拒绝安装', () async {
    final zip = await buildZip(includeManifest: false);
    final entry = entryFor(sha: zip.sha);

    await expectLater(
      installer.install(entry, packageUrl: Uri.file(zip.path)),
      throwsA(isA<PluginInstallException>()),
    );
    expect(await installer.store.find('pomodoro'), isNull);
  });

  test('契约版本不受支持：在下载之前就拒绝', () async {
    final zip = await buildZip();
    final entry = entryFor(sha: zip.sha, contract: 99);

    await expectLater(
      installer.install(entry, packageUrl: Uri.file(zip.path)),
      throwsA(isA<PluginInstallException>()),
    );
  });

  test('升级：旧版本目录被删，只剩一条登记', () async {
    final v1 = await buildZip(version: '1.0.0');
    await installer.install(
      entryFor(version: '1.0.0', sha: v1.sha),
      packageUrl: Uri.file(v1.path),
    );

    final v2 = await buildZip(version: '1.1.0');
    await installer.install(
      entryFor(version: '1.1.0', sha: v2.sha),
      packageUrl: Uri.file(v2.path),
    );

    final dirs = await Directory(p.join(pluginRoot.path, 'pomodoro'))
        .list()
        .where((e) => e is Directory)
        .map((e) => p.basename(e.path))
        .toList();
    expect(dirs, <String>['1.1.0'], reason: '旧版本应该被清掉');

    final all = await installer.store.all();
    expect(all, hasLength(1));
    expect(all.single.version, '1.1.0');
  });

  test('卸载：目录与登记一起消失', () async {
    final zip = await buildZip();
    await installer.install(
      entryFor(sha: zip.sha),
      packageUrl: Uri.file(zip.path),
    );

    await installer.uninstall('pomodoro');

    expect(await installer.store.find('pomodoro'), isNull);
    expect(await Directory(p.join(pluginRoot.path, 'pomodoro')).exists(), isFalse);
  });

  test('自愈：目录没了就删登记；登记没了就删目录', () async {
    final zip = await buildZip();
    await installer.install(
      entryFor(sha: zip.sha),
      packageUrl: Uri.file(zip.path),
    );

    // 1) 手动删掉文件，模拟"被清理软件删了"
    await Directory(p.join(pluginRoot.path, 'pomodoro')).delete(recursive: true);
    var report = await installer.reconcile();
    expect(report.removedRecords, <String>['pomodoro']);
    expect(await installer.store.find('pomodoro'), isNull);

    // 2) 手动放一个没登记过的目录，模拟"上次卸载没删干净"
    final orphan = Directory(p.join(pluginRoot.path, 'ghost', '1.0.0'));
    await orphan.create(recursive: true);
    report = await installer.reconcile();
    expect(report.removedDirs, <String>['ghost']);
    expect(await orphan.exists(), isFalse);
  });
}
