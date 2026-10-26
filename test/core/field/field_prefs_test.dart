// 字段偏好的纯逻辑测试。
//
// 这一层最容易出的不是崩溃，而是"悄悄变了"：
// 顺序丢了、锁定字段被关掉了、默认值指向一个界面画不出来的档位。
// 所以断言写得比较细。

import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/field/field_prefs.dart';
import 'package:v5_app/core/field/task_field.dart';

void main() {
  group('出厂偏好', () {
    test('顺序就是字段目录顺序，且没有关掉的字段', () {
      final prefs = FieldPrefs.initial();

      expect(prefs.ordered(FieldCatalog.all).map((f) => f.id),
          FieldCatalog.all.map((f) => f.id));
      expect(prefs.hidden, isEmpty);
    });

    test('出厂时默认值取字段自带的（优先级白、时长不设）', () {
      final prefs = FieldPrefs.initial();

      expect(prefs.defaultOf(FieldCatalog.priority), 'white');
      expect(prefs.defaultOf(FieldCatalog.minutes), isNull);
    });
  });

  group('解析容错', () {
    test('坏 JSON / 空值都回到出厂设置，不抛异常', () {
      expect(FieldPrefs.decode(null).encode(), FieldPrefs.initial().encode());
      expect(FieldPrefs.decode('not json').encode(), FieldPrefs.initial().encode());
      expect(FieldPrefs.decode('[]').encode(), FieldPrefs.initial().encode());
    });

    test('主包删掉的字段 id 会被丢掉', () {
      final prefs = FieldPrefs.decode(
        '{"order":["gone","title","due_date"],"hidden":[],"defaults":{}}',
      );

      expect(prefs.ordered(FieldCatalog.all).first.id, 'title');
      expect(prefs.ordered(FieldCatalog.all).length, FieldCatalog.all.length,
          reason: '缺的字段要补到末尾，不能少');
    });

    test('主包新加的字段（偏好里没有）会自动追加到末尾', () {
      final prefs = FieldPrefs.decode('{"order":["title"],"hidden":[]}');
      final ids = prefs.ordered(FieldCatalog.all).map((f) => f.id).toList();

      expect(ids.first, 'title');
      expect(ids.length, FieldCatalog.all.length);
    });

    test('锁定字段就算被写进 hidden，也不会真的关掉', () {
      final prefs = FieldPrefs.decode('{"order":[],"hidden":["title","due_date"]}');

      expect(prefs.isHidden('title'), isFalse);
      expect(prefs.isHidden('due_date'), isFalse);
    });

    test('默认值只收枚举字段的合法档位，非法值直接丢弃', () {
      final prefs = FieldPrefs.decode(
        '{"order":[],"hidden":[],"defaults":{'
        '"priority":"purple",' // 不在档位里
        '"description":"随便写",' // 文本字段不该有默认值
        '"estimated_minutes":"60"' // 合法
        '}}',
      );

      expect(prefs.defaultOf(FieldCatalog.priority), 'white', reason: '非法值不能生效');
      expect(prefs.defaults.containsKey('description'), isFalse);
      expect(prefs.defaultOf(FieldCatalog.minutes), '60');
    });
  });

  group('开关与顺序', () {
    test('关掉字段后 enabled 里就没有它，但 ordered 里还在（管理页要能再打开）', () {
      final prefs = FieldPrefs.initial().withHidden('description', false);

      expect(prefs.enabled(FieldCatalog.all).map((f) => f.id), isNot(contains('description')));
      expect(prefs.ordered(FieldCatalog.all).map((f) => f.id), contains('description'));
    });

    test('拖拽换位写回的是完整顺序，不只是可见部分', () {
      final prefs = FieldPrefs.initial().reorder(0, 2, FieldCatalog.all);
      final ids = prefs.ordered(FieldCatalog.all).map((f) => f.id).toList();

      expect(ids[1], FieldCatalog.title.id);
      expect(ids.length, FieldCatalog.all.length);
    });

    test('越界的换位请求被忽略，不会抛', () {
      final prefs = FieldPrefs.initial();
      expect(prefs.reorder(99, 0, FieldCatalog.all).encode(), prefs.encode());
      expect(prefs.reorder(0, 99, FieldCatalog.all).encode(), prefs.encode());
    });
  });

  group('序列化', () {
    test('编码再解码，内容一致', () {
      final prefs = FieldPrefs.initial()
          .withHidden('tags', false)
          .withDefault('priority', 'orange')
          .reorder(0, 3, FieldCatalog.all);

      final round = FieldPrefs.decode(prefs.encode());

      expect(round.encode(), prefs.encode());
      expect(round.isHidden('tags'), isTrue);
      expect(round.defaultOf(FieldCatalog.priority), 'orange');
    });

    test('默认值可以清回字段自带默认', () {
      final prefs = FieldPrefs.initial()
          .withDefault('priority', 'orange')
          .withDefault('priority', null);

      expect(prefs.defaultOf(FieldCatalog.priority), 'white');
    });
  });

  group('被藏起来但有内容的字段', () {
    test('只报有值的，没值的不打扰', () {
      final prefs = FieldPrefs.initial()
          .withHidden('description', false)
          .withHidden('estimated_minutes', false);

      final hidden = prefs.hiddenWithValue(
        FieldCatalog.all,
        (field) => field.id == 'description',
      );

      expect(hidden.map((f) => f.id), <String>['description']);
    });
  });
}
