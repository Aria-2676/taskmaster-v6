// 权限 → 人话。
//
// 为什么单独放一层：权限 id 是给代码看的（`task:write`），用户看到的必须是
// "能改你的任务"。这句话写错比没有更糟 —— 用户会以为它只是只读的。
//
// 新增权限时必须同时在这里加一句，否则界面上会露出 `未知权限：xxx`
// （故意不做"兜底成人话"，就是为了让漏写能被一眼看见）。

/// 权限的中文说明。
class PermissionCopy {
  const PermissionCopy._();

  /// 能读到哪些数据 —— 用来回答"它要看什么"
  static const Map<String, String> _labels = <String, String>{
    'task:read': '读取你的任务（标题、日期、优先级、标签）',
    'task:write': '新建和修改你的任务',
    'task:delete': '删除你的任务',
    'tag:read': '读取你的标签',
  };

  /// 会造成不可逆后果的权限。展示时要单独提出来说一句。
  static const Set<String> destructive = <String>{'task:delete'};

  static String label(String permission) =>
      _labels[permission] ?? '未知权限：$permission';

  static bool isDestructive(String permission) =>
      destructive.contains(permission);

  /// 展示顺序：读 → 写 → 删。删除永远排最后，因为它最需要被看见。
  static const List<String> _order = <String>[
    'task:read',
    'tag:read',
    'task:write',
    'task:delete',
  ];

  static List<String> sorted(Iterable<String> permissions) {
    final list = permissions.toList();
    list.sort((a, b) {
      final ai = _order.indexOf(a);
      final bi = _order.indexOf(b);
      return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
    });
    return list;
  }
}
