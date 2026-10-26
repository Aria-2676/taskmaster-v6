// 权限文案与索引解析。
//
// 盯两件事：未知权限不能被"兜底成人话"（要露原文，否则漏写永远发现不了），
// 以及删除权限在展示顺序里必须最后出现。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/plugin/permission_copy.dart';
import 'package:v5_app/core/plugin/plugin_index.dart';

void main() {
  group('PermissionCopy', () {
    test('已知权限翻成人话，未知权限露出原文', () {
      expect(PermissionCopy.label('task:write'), '新建和修改你的任务');
      expect(PermissionCopy.label('task:delete'), '删除你的任务');
      expect(PermissionCopy.label('points:read'), '未知权限：points:read');
    });

    test('只有删除算不可逆', () {
      expect(PermissionCopy.isDestructive('task:delete'), isTrue);
      expect(PermissionCopy.isDestructive('task:write'), isFalse);
      expect(PermissionCopy.isDestructive('task:read'), isFalse);
    });

    test('展示顺序：读 → 写 → 删（删永远最后，它最需要被看见）', () {
      final sorted = PermissionCopy.sorted(<String>[
        'task:delete',
        'tag:read',
        'task:write',
        'task:read',
      ]);

      expect(sorted, <String>['task:read', 'tag:read', 'task:write', 'task:delete']);
    });

    test('不认识的权限排在已知之后，不丢也不前插', () {
      final sorted = PermissionCopy.sorted(<String>['zzz:unknown', 'task:read']);
      expect(sorted.first, 'task:read');
      expect(sorted, contains('zzz:unknown'));
    });
  });

  group('索引里的权限', () {
    PluginIndexEntry parse(Object? permissions) => PluginIndexEntry.fromJson(
          <String, Object?>{
            'id': 'demo_help',
            'name': '使用说明',
            'version': '1.0.0',
            'contract': 1,
            'permissions': permissions,
            'package': <String, Object?>{
              'path': 'assets/plugins/x.zip',
              'sha256': 'a' * 64,
              'sizeBytes': 10,
            },
          },
        );

    test('正常解析', () {
      final entry = parse(<String>['task:read', 'task:write']);
      expect(entry.permissions, <String>{'task:read', 'task:write'});
    });

    test('宿主不认识的权限被丢掉，不影响整条索引', () {
      final entry = parse(<String>['task:read', 'points:read']);
      expect(entry.permissions, <String>{'task:read'});
    });

    test('缺 permissions 字段时是空集（老索引仍然可用）', () {
      expect(parse(null).permissions, isEmpty);
      expect(parse('not-a-list').permissions, isEmpty);
    });
  });
}
