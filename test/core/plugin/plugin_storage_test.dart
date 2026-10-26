// 插件私有表：声明、建表、受限读写。
//
// 这块是安全边界所在，所以测的重点不是"能存能取"，而是**不能做什么**：
// 访问没声明的表、写没声明的列、不带条件地清空、把 SQL 塞进字段名。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:v5_app/core/data/v6_database.dart';
import 'package:v5_app/core/data/v6_plugin_tables.dart';
import 'package:v5_app/core/data/v6_schema.dart';
import 'package:v5_app/core/plugin/plugin_manifest.dart';
import 'package:v5_app/core/plugin/plugin_storage.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('声明解析', () {
    Map<String, Object?> storageJson(Object? tables, {int? version}) => <String, Object?>{
          if (version != null) 'version': version,
          'tables': tables,
        };

    test('正常声明：表、列、唯一、索引都解析出来', () {
      final spec = PluginStorageSpec.fromJson(storageJson(<Object?>[
        <String, Object?>{
          'name': 'entries',
          'columns': <Object?>[
            <String, Object?>{'name': 'day', 'type': 'text', 'notNull': true},
            <String, Object?>{'name': 'body', 'type': 'text'},
            <String, Object?>{'name': 'mood', 'type': 'integer', 'default': 3},
          ],
          'unique': <Object?>[
            <Object?>['day'],
          ],
          'indexes': <Object?>[
            <Object?>['mood'],
          ],
        },
      ]));

      final table = spec.table('entries')!;
      expect(table.columns.map((c) => c.name), <String>['day', 'body', 'mood']);
      expect(table.unique, <List<String>>[
        <String>['day'],
      ]);
      expect(table.indexes, <List<String>>[
        <String>['mood'],
      ]);
      expect(table.columns.first.notNull, isTrue);
    });

    test('列类型只认 text / integer / real', () {
      expect(
        () => PluginStorageSpec.fromJson(storageJson(<Object?>[
          <String, Object?>{
            'name': 't',
            'columns': <Object?>[
              <String, Object?>{'name': 'blob_col', 'type': 'blob'},
            ],
          },
        ])),
        throwsA(isA<PluginStorageException>()),
      );
    });

    test('插件不能自己声明 id（宿主提供）', () {
      expect(
        () => PluginStorageSpec.fromJson(storageJson(<Object?>[
          <String, Object?>{
            'name': 't',
            'columns': <Object?>[
              <String, Object?>{'name': 'id', 'type': 'integer'},
            ],
          },
        ])),
        throwsA(isA<PluginStorageException>()),
      );
    });

    test('表名/列名非法直接拒绝（它们会进 SQL 标识符）', () {
      for (final bad in <String>['Entries', 'a-b', '1abc', 'a b']) {
        expect(
          () => PluginStorageSpec.fromJson(storageJson(<Object?>[
            <String, Object?>{
              'name': bad,
              'columns': <Object?>[
                <String, Object?>{'name': 'x', 'type': 'text'},
              ],
            },
          ])),
          throwsA(isA<PluginStorageException>()),
          reason: '应该拒绝表名：$bad',
        );
      }
    });

    test('重复表名 / 超过 8 张表 都拒绝', () {
      Map<String, Object?> table(String name) => <String, Object?>{
            'name': name,
            'columns': <Object?>[
              <String, Object?>{'name': 'x', 'type': 'text'},
            ],
          };

      expect(
        () => PluginStorageSpec.fromJson(storageJson(<Object?>[table('a'), table('a')])),
        throwsA(isA<PluginStorageException>()),
      );
      expect(
        () => PluginStorageSpec.fromJson(storageJson(<Object?>[
          for (var i = 0; i < 9; i++) table('t$i'),
        ])),
        throwsA(isA<PluginStorageException>()),
      );
    });

    test('没声明 storage 就是空（只读写任务的那类插件）', () {
      final spec = PluginStorageSpec.fromJson(null);
      expect(spec.isEmpty, isTrue);
    });
  });

  group('建表', () {
    late Database db;
    late PluginSchemaRegistry registry;

    setUp(() async {
      db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      addTearDown(db.close);
      registry = PluginSchemaRegistry();
    });

    test('表名强制带 plg_<id>_ 前缀，索引也一起建', () async {
      final spec = PluginStorageSpec.fromJson(<String, Object?>{
        'tables': <Object?>[
          <String, Object?>{
            'name': 'entries',
            'columns': <Object?>[
              <String, Object?>{'name': 'day', 'type': 'text'},
              <String, Object?>{'name': 'mood', 'type': 'integer'},
            ],
            'unique': <Object?>[
              <Object?>['day'],
            ],
            'indexes': <Object?>[
              <Object?>['mood'],
            ],
          },
        ],
      });

      registry.registerStorage('demo_help', spec);
      await registry.materialize(db);

      expect(registry.tableNamesOf('demo_help'), <String>['plg_demo_help_entries']);
      final tables = await V6Database.listTables(db);
      expect(tables, contains('plg_demo_help_entries'));

      // 唯一约束真的生效：同一天插两次要失败
      await db.insert('plg_demo_help_entries', <String, Object?>{'day': '2026-10-27', 'mood': 4});
      await expectLater(
        db.insert('plg_demo_help_entries', <String, Object?>{'day': '2026-10-27', 'mood': 5}),
        throwsA(anything),
      );

      // 迁移记录里查得到
      final rows = await db.query(V6Table.pluginMigrations);
      expect(rows.single[PluginMigrationCol.tableName], 'plg_demo_help_entries');
    });

    test('卸载插件会把它的表删掉，主包表不受影响', () async {
      registry.registerStorage(
        'demo_help',
        PluginStorageSpec.fromJson(<String, Object?>{
          'tables': <Object?>[
            <String, Object?>{
              'name': 'entries',
              'columns': <Object?>[
                <String, Object?>{'name': 'day', 'type': 'text'},
              ],
            },
          ],
        }),
      );
      await registry.materialize(db);
      await registry.dropPlugin(db, 'demo_help');

      final tables = await V6Database.listTables(db);
      expect(tables, isNot(contains('plg_demo_help_entries')));
      expect(tables, contains(V6Table.tasks), reason: '主包表不能被误删');
    });
  });

  group('受限读写', () {
    late Database db;
    late PluginDataStore store;

    setUp(() async {
      db = await V6Database.open(
        path: inMemoryDatabasePath,
        pluginSchema: PluginSchemaRegistry(),
      );
      addTearDown(db.close);

      final spec = PluginStorageSpec.fromJson(<String, Object?>{
        'tables': <Object?>[
          <String, Object?>{
            'name': 'entries',
            'columns': <Object?>[
              <String, Object?>{'name': 'day', 'type': 'text'},
              <String, Object?>{'name': 'body', 'type': 'text'},
              <String, Object?>{'name': 'minutes', 'type': 'integer'},
            ],
          },
        ],
      });
      final registry = PluginSchemaRegistry();
      registry.registerStorage('demo_help', spec);
      await registry.materialize(db);
      store = PluginDataStore(db: db, pluginId: 'demo_help', spec: spec);
    });

    test('插入 → 查询 → 更新 → 删除 全链路', () async {
      final id = await store.insert('entries', <String, Object?>{
        'day': '2026-10-27',
        'body': '第一条',
        'minutes': 25,
      });

      var rows = await store.select('entries');
      expect(rows.single['body'], '第一条');
      expect(rows.single['id'], id);

      await store.update('entries', <String, Object?>{'body': '改过了'}, <Object?>[
        <String, Object?>{'column': 'id', 'op': '=', 'value': id},
      ]);
      rows = await store.select('entries');
      expect(rows.single['body'], '改过了');

      final deleted = await store.delete('entries', <Object?>[
        <String, Object?>{'column': 'id', 'value': id},
      ]);
      expect(deleted, 1);
      expect(await store.select('entries'), isEmpty);
    });

    test('where 支持 in / isNull / 比较符', () async {
      await store.insert('entries', <String, Object?>{'day': '2026-10-26', 'minutes': 10});
      await store.insert('entries', <String, Object?>{'day': '2026-10-27', 'minutes': 30});
      await store.insert('entries', <String, Object?>{'day': '2026-10-28'});

      final inRange = await store.select('entries', where: <Object?>[
        <String, Object?>{
          'column': 'day',
          'op': 'in',
          'value': <String>['2026-10-26', '2026-10-27'],
        },
        <String, Object?>{'column': 'minutes', 'op': '>=', 'value': 10},
      ]);
      expect(inRange, hasLength(2));

      final nulls = await store.select('entries', where: <Object?>[
        <String, Object?>{'column': 'minutes', 'op': 'isNull'},
      ]);
      expect(nulls.single['day'], '2026-10-28');
    });

    test('聚合：按天分组求和（统计插件要的就是这个）', () async {
      await store.insert('entries', <String, Object?>{'day': '2026-10-26', 'minutes': 10});
      await store.insert('entries', <String, Object?>{'day': '2026-10-26', 'minutes': 20});
      await store.insert('entries', <String, Object?>{'day': '2026-10-27', 'minutes': 5});

      final rows = await store.aggregate(
        'entries',
        groupBy: <String>['day'],
        metrics: <Map<String, Object?>>[
          <String, Object?>{'fn': 'count', 'column': '*', 'as': 'n'},
          <String, Object?>{'fn': 'sum', 'column': 'minutes', 'as': 'total'},
        ],
      );

      expect(rows, hasLength(2));
      final first = rows.firstWhere((r) => r['day'] == '2026-10-26');
      expect(first['n'], 2);
      expect(first['total'], 30);
    });

    test('select 有默认上限，不能一次拉全库', () async {
      for (var i = 0; i < 120; i++) {
        await store.insert('entries', <String, Object?>{'day': '2026-10-27', 'minutes': i});
      }
      final rows = await store.select('entries');
      expect(rows, hasLength(100));
      expect(await store.select('entries', limit: 500), hasLength(120));
    });

    group('不该能干的事', () {
      test('访问没声明的表', () async {
        await expectLater(
          store.select('tasks'),
          throwsA(isA<PluginDataException>()),
          reason: '主包表绝不能通过这条路被读到',
        );
      });

      test('写没声明的列（顺带试一下把 SQL 塞进列名）', () async {
        await expectLater(
          store.insert('entries', <String, Object?>{'secret': 'x'}),
          throwsA(isA<PluginDataException>()),
        );
        await expectLater(
          store.insert('entries', <String, Object?>{
            'body; DROP TABLE tasks; --': 'x',
          }),
          throwsA(isA<PluginDataException>()),
        );
      });

      test('不带条件地 update / delete（等于清库）', () async {
        await store.insert('entries', <String, Object?>{'body': 'x'});
        await expectLater(
          store.update('entries', <String, Object?>{'body': 'y'}, null),
          throwsA(isA<PluginDataException>()),
        );
        await expectLater(
          store.delete('entries', null),
          throwsA(isA<PluginDataException>()),
        );
        expect(await store.select('entries'), hasLength(1));
      });

      test('不支持的比较符 / 聚合函数', () async {
        await expectLater(
          store.select('entries', where: <Object?>[
            <String, Object?>{'column': 'day', 'op': 'regexp', 'value': 'x'},
          ]),
          throwsA(isA<PluginDataException>()),
        );
        await expectLater(
          store.aggregate('entries', metrics: <Map<String, Object?>>[
            <String, Object?>{'fn': 'drop', 'column': 'day', 'as': 'x'},
          ]),
          throwsA(isA<PluginDataException>()),
        );
      });
    });
  });

  group('manifest 里的 storage', () {
    test('声明被解析进 PluginManifest', () {
      final manifest = PluginManifest.parse(<String, Object?>{
        'id': 'demo_help',
        'name': '使用说明',
        'version': '1.0.0',
        'contract': 1,
        'entry': 'index.html',
        'storage': <String, Object?>{
          'tables': <Object?>[
            <String, Object?>{
              'name': 'entries',
              'columns': <Object?>[
                <String, Object?>{'name': 'day', 'type': 'text'},
              ],
            },
          ],
        },
      });

      expect(manifest.storage.tables, hasLength(1));
      expect(manifest.storage.table('entries')!.columns.single.name, 'day');
    });

    test('不写 storage 的插件照常可装', () {
      final manifest = PluginManifest.parse(<String, Object?>{
        'id': 'demo_help',
        'name': '使用说明',
        'version': '1.0.0',
        'contract': 1,
        'entry': 'index.html',
      });
      expect(manifest.storage.isEmpty, isTrue);
    });
  });
}
