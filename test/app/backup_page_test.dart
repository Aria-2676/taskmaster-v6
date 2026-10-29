// 备份页与文件仓库。
//
// 重点守两条用户明确要的规则：
//   1. 已装插件的默认勾上，**已卸载但留了数据的默认不勾**（但要在下面提示有几项没选）
//   2. 恢复前的确认框要写具体条数，不能只说"确定吗"

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/app/data/backup_repository.dart';
import 'package:v5_app/app/pages/backup_page.dart';
import 'package:v5_app/core/backup/backup_service.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late Directory dir;
  late BackupService service;
  late BackupRepository repository;

  setUp(() async {
    db = await V6Database.open(
      path: inMemoryDatabasePath,
      pluginSchema: PluginSchemaRegistry(),
    );
    dir = await Directory.systemTemp.createTemp('v6_backup_');
    repository = BackupRepository(overrideDir: dir);
    service = BackupService(db);

    await db.insert(V6Table.tasks, <String, Object?>{
      TaskCol.id: 1,
      TaskCol.title: '买牛奶',
      TaskCol.createdAt: '2026-10-28T01:00:00Z',
      TaskCol.cplTime: '2026-10-28',
    });

    // 已装插件
    await db.execute('CREATE TABLE plg_energy_currency_entries (id INTEGER PRIMARY KEY, note TEXT)');
    await db.insert('plg_energy_currency_entries', <String, Object?>{'note': 'x'});
    await db.insert(V6Table.pluginMigrations, <String, Object?>{
      'plugin_id': 'energy_currency',
      'table_name': 'plg_energy_currency_entries',
      'version': 1,
      'created_at': '2026-10-28T00:00:00Z',
    });
    await db.insert(V6Table.installedPlugins, <String, Object?>{
      'plugin_id': 'energy_currency',
      'version': '1.0.0',
      'contract': 1,
      'install_dir': 'energy_currency/1.0.0',
      'installed_at': '2026-10-28T00:00:00Z',
      'enabled': 1,
    });

    // 已卸载但留了数据的插件
    await db.execute('CREATE TABLE plg_old_thing_entries (id INTEGER PRIMARY KEY, note TEXT)');
    // 卸载时选了"保留数据"，所以表里有内容 —— 这才是要提醒用户"你没勾"的场景
    await db.insert('plg_old_thing_entries', <String, Object?>{'note': '旧数据'});
    await db.insert(V6Table.pluginMigrations, <String, Object?>{
      'plugin_id': 'old_thing',
      'table_name': 'plg_old_thing_entries',
      'version': 1,
      'created_at': '2026-10-27T00:00:00Z',
    });
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// 等页面稳定。手机分辨率下 pump 一次不便宜，所以**稳定就提前退出**：
  /// 连续 3 帧没有新帧调度就认为动画与异步都跑完了（文件 IO 靠 runAsync 让出）。
  Future<void> settle(WidgetTester tester) async {
    var idle = 0;
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
      await tester.pump();
      idle = tester.binding.hasScheduledFrame ? 0 : idle + 1;
      if (idle >= 3) return;
    }
  }

  Widget page() => MaterialApp(
        home: BackupPage(
          service: service,
          repository: repository,
          appVersion: '6.0.0+6000',
          nameOf: (id) => id == 'energy_currency' ? '能量' : id,
        ),
      );

  /// 按手机尺寸起页。默认测试窗口是 800×600，勾选面板（四段 + 插件行）
  /// 在里面放不下，确认按钮会被排到屏幕外 —— tap 落空，看着像"点不动"。
  Future<void> pumpPage(WidgetTester tester, {Size size = const Size(1080, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(page());
  }

  group('文件仓库', () {
    test('存一份就能列出来，摘要与大小对得上', () async {
      final data = await service.collect(appVersion: '6.0.0+6000');
      final saved = await repository.save(service.pack(data), manifest: data.manifest);

      final files = await repository.list();
      expect(files, hasLength(1));
      expect(files.single.path, saved.path);
      expect(files.single.manifest.summary, contains('任务 1'));
      expect(files.single.sizeBytes, greaterThan(0));
    });

    test('新的排在前面', () async {
      final data = await service.collect(appVersion: '6.0.0+6000');
      await repository.save(service.pack(data),
          manifest: data.manifest, now: DateTime(2026, 10, 28, 9));
      await repository.save(service.pack(data),
          manifest: data.manifest, now: DateTime(2026, 10, 28, 18));

      final files = await repository.list();
      expect(files.first.name, contains('20261028-180000'));
    });

    test('不是备份的 zip 不列出来，但也别删掉它', () async {
      final archive = Archive();
      final bytes = utf8.encode('random');
      archive.addFile(ArchiveFile('other.txt', bytes.length, bytes));
      final junk = File(p.join(dir.path, 'junk.zip'));
      await junk.writeAsBytes(ZipEncoder().encode(archive));

      expect(await repository.list(), isEmpty);
      expect(await junk.exists(), isTrue, reason: '不认识的文件不该被清掉');
    });

    test('超过保留上限：只提示，不自动删', () async {
      final data = await service.collect(appVersion: '6.0.0+6000');
      for (var i = 0; i < BackupRepository.keepLimit + 1; i++) {
        await repository.save(service.pack(data),
            manifest: data.manifest, now: DateTime(2026, 10, 28, 0, i));
      }

      final files = await repository.list();
      expect(files, hasLength(BackupRepository.keepLimit + 1));
      expect(repository.overLimit(files), hasLength(1));
    });
  });

  group('备份页', () {
    testWidgets('没有备份时给一句话 + 右上角能建', (tester) async {
      await pumpPage(tester);
      await settle(tester);

      expect(find.text('还没有备份'), findsOneWidget);
      expect(find.byTooltip('新建备份'), findsOneWidget);
    });

    testWidgets('勾选面板：已装默认勾，已卸载留数据的默认不勾但会提示', (tester) async {
      await pumpPage(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('新建备份'));
      await settle(tester);

      expect(find.text('新建备份'), findsWidgets);
      expect(find.text('能量'), findsOneWidget);
      // 备注是拼在副标题里的（"1 条数据 · 已卸载，数据还在"），所以用 contains
      expect(find.textContaining('已卸载，数据还在'), findsOneWidget);

      final boxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      final byTitle = <String, bool>{
        for (final tile in boxes) (tile.title as Text).data!: tile.value ?? false,
      };
      expect(byTitle['任务'], isTrue);
      expect(byTitle['能量'], isTrue, reason: '已装插件默认勾');
      expect(byTitle['old_thing'], isFalse, reason: '已卸载的默认不勾');
      // 提示语要说清"你放弃了什么"
      expect(find.textContaining('遗留数据没选'), findsOneWidget);
    });

    testWidgets('列表里能看到摘要与「恢复」', (tester) async {
      // 直接落一份备份再看列表：原来这条是"点 + 号 → 点生成备份"，
      // 但那个弹层的确认按钮在测试视口里算出来的位置不对（见下一条守卫），
      // 导致这里断言的其实是"按钮点没点到"，不是"列表渲染得对不对"。
      // **真实文件 IO 必须包在 runAsync 里**：testWidgets 默认在 FakeAsync 区域里跑，
      // 直接 await 一个 dart:io 会永远不返回（表现为"这条测试跑不完"）。
      await tester.runAsync(() async {
        final data = await service.collect(appVersion: '6.0.0+6000');
        await repository.save(service.pack(data), manifest: data.manifest);
      });

      await pumpPage(tester);
      await settle(tester);

      expect(find.textContaining('任务 1'), findsOneWidget);
      expect(find.text('恢复'), findsOneWidget);
    });

    test('恢复确认框要写具体条数（不靠弹层，直接测文案）', () async {
      final data = await service.collect(appVersion: '6.0.0+6000');

      final lines = restoreConfirmLines(
        data,
        tasks: true,
        tags: true,
        settings: true,
        recycleBin: false,
        pluginIds: const <String>{'energy_currency'},
        nameOf: (id) => id,
      );

      expect(lines, contains(contains('会覆盖当前全部任务')));
      expect(lines.any((line) => line.contains('1 条')), isTrue,
          reason: '要写具体条数，不能只说"确定吗"');
      expect(lines, contains(contains('energy_currency')));
    });
  });
}
