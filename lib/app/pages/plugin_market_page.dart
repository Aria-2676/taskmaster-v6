import 'package:flutter/material.dart';

import '../../core/plugin/permission_copy.dart';
import '../../core/plugin/plugin_index.dart';
import '../../core/plugin/plugin_store.dart';
import '../state/plugin_market_store.dart';

/// 插件市场：上「已安装」，下「可安装」。
///
/// 首版索引来自内置 asset（只有一个验证用的示例插件），**不联网也能打开**。
/// 索引取不到时只影响下半页，已安装部分照常可用。
class PluginMarketPage extends StatefulWidget {
  const PluginMarketPage({super.key, required this.store});

  final PluginMarketStore store;

  @override
  State<PluginMarketPage> createState() => _PluginMarketPageState();
}

class _PluginMarketPageState extends State<PluginMarketPage> {
  @override
  void initState() {
    super.initState();
    widget.store.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final store = widget.store;
        return Scaffold(
          appBar: AppBar(
            title: const Text('插件市场', style: TextStyle(fontSize: 16)),
          ),
          body: store.loading && store.installed.isEmpty
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _buildList(context, store),
        );
      },
    );
  }

  Widget _buildList(BuildContext context, PluginMarketStore store) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
      children: <Widget>[
        _sectionHeader('已安装 · ${store.installed.length}'),
        if (store.installed.isEmpty)
          _EmptyBox(
            icon: Icons.widgets_outlined,
            text: '还没有安装插件',
            hint: '下面装一个试试',
          )
        else
          for (final item in store.installed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PluginTile(
                title: _nameOf(store, item.pluginId),
                subtitle: _installedSubtitle(store, item),
                iconName: store.index.findById(item.pluginId)?.icon,
                seed: item.pluginId,
                action: _installedAction(context, store, item),
              ),
            ),
        const SizedBox(height: 18),
        _sectionHeader('可安装 · ${store.available.length}'),
        if (store.indexError != null)
          _EmptyBox(
            icon: Icons.cloud_off_outlined,
            text: '索引没取到',
            // 把原始错误露出来。上一版只写了"索引没取到"，
            // 结果"asset 没打进包"这种硬错误被文案吞掉了，只能靠翻代码才知道
            hint: _shortError(store.indexError),
          )
        else if (store.available.isEmpty)
          _EmptyBox(
            icon: Icons.download_outlined,
            text: '暂无可用插件',
            hint: '离线时只显示已安装的',
          )
        else
          for (final entry in store.available)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PluginTile(
                title: entry.name,
                subtitle: 'v${entry.version} · ${_formatSize(entry.package.sizeBytes)}',
                description: entry.description,
                iconName: entry.icon,
                seed: entry.id,
                action: _actionFor(context, store, entry),
              ),
            ),
        const SizedBox(height: 14),
        Text(
          '装完会在侧边栏出现入口；卸载后入口和它占的空间一起消失。',
          style: TextStyle(fontSize: 11.5, height: 1.6, color: muted),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
      child: Builder(
        builder: (context) => Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  String _nameOf(PluginMarketStore store, String pluginId) =>
      store.index.findById(pluginId)?.name ?? pluginId;

  /// 已安装条目的动作区：有新版本时「升级」在前，卸载永远在。
  /// 已安装条目的副标题：版本（有新版就写成 `旧 → 新`）+ 停用标记。
  ///
  /// 「已停用」必须写成**字**，不能只靠灰一下：光变灰的话用户会以为
  /// 是加载中或者坏了，然后去点卸载。
  String _installedSubtitle(PluginMarketStore store, InstalledPlugin item) {
    final update = store.updateFor(item);
    final base = update == null
        ? 'v${item.version} · 契约 ${item.contract}'
        : 'v${item.version} → v${update.version}';
    return item.enabled ? base : '$base · 已停用';
  }

  Widget _installedAction(
    BuildContext context,
    PluginMarketStore store,
    InstalledPlugin item,
  ) {
    final update = store.updateFor(item);
    final buttons = <Widget>[
      if (update != null)
        _PillButton(
          label: '升级',
          primary: true,
          onTap: () => _confirmInstall(context, store, update, isUpdate: true),
        ),
      if (update != null) const SizedBox(width: 6),
      _DangerButton(
        label: '卸载',
        onTap: () => _confirmUninstall(context, store, item),
      ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 开关放在按钮左边：右边留给"破坏性"的那个（卸载），
        // 两者颜色和形态都不一样，不会误触。
        _EnableSwitch(
          value: item.enabled,
          onChanged: (value) => _toggleEnabled(store, item, value),
        ),
        const SizedBox(width: 2),
        ...buttons,
      ],
    );
  }

  /// 停用 / 启用。**不弹确认**：它不删任何东西，随手能开回来；
  /// 弹框只会让这个高频小开关变得烦人。
  Future<void> _toggleEnabled(
    PluginMarketStore store,
    InstalledPlugin item,
    bool enabled,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = _nameOf(store, item.pluginId);
    try {
      await store.setEnabled(item.pluginId, enabled);
      messenger.showSnackBar(
        SnackBar(
          content: Text(enabled ? '已启用「$name」' : '已停用「$name」，入口和货币位已撤下'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }

  Widget _actionFor(BuildContext context, PluginMarketStore store, PluginIndexEntry entry) {
    final progress = store.progressOf(entry.id);
    if (progress != null) {
      return SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(progress * 100).round()}%',
              style: TextStyle(
                fontSize: 10.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    if (!entry.installable) {
      return Text(
        '需要更新',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    return _PillButton(
      label: '安装',
      primary: true,
      // 先告知再装：卡片上常驻一行是浏览态，用户不会读；
      // 点下去那一刻才是决定时刻，把"它能干什么"摆在这里才有用。
      onTap: () => _confirmInstall(context, store, entry),
    );
  }

  /// 安装前告知权限。**没有权限也要弹** ——
  /// 让"这个插件什么都不碰"成为一个明确的信息，而不是一片空白。
  ///
  /// [isUpdate] 时走升级话术：覆盖安装不清插件自己的数据，这句必须说，
  /// 否则用户会以为升级 = 卸载重装、攒的数据没了。
  Future<void> _confirmInstall(
    BuildContext context,
    PluginMarketStore store,
    PluginIndexEntry entry, {
    bool isUpdate = false,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final permissions = PermissionCopy.sorted(entry.permissions);
    final hasDestructive = permissions.any(PermissionCopy.isDestructive);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isUpdate ? '升级「${entry.name}」？' : '安装「${entry.name}」？',
          style: const TextStyle(fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'v${entry.version} · ${_formatSize(entry.package.sizeBytes)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            if (isUpdate) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '升级会保留这个插件已有的数据。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 14),
            if (permissions.isEmpty)
              Text(
                '这个插件不需要任何数据权限。',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              )
            else ...<Widget>[
              const Text('安装后它可以：', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final permission in permissions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: PermissionCopy.isDestructive(permission)
                                ? scheme.error
                                : scheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          PermissionCopy.label(permission),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: PermissionCopy.isDestructive(permission)
                                ? scheme.error
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (hasDestructive) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  '删除不可逆；如果你开着回收站，被删的任务仍然会先进回收站。',
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: scheme.outline),
                ),
              ],
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isUpdate ? '升级' : '安装'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _install(store, entry);
  }

  Future<void> _install(PluginMarketStore store, PluginIndexEntry entry) async {
    try {
      await store.install(entry);
    } catch (_) {
      if (!mounted) return;
      _toast(store.lastError ?? '安装失败');
      store.clearError();
    }
  }

  /// 卸载确认。**默认保留数据**，勾一下才连数据一起删。
  ///
  /// 为什么默认保留：卸载是"我不想用了"，不等于"把攒的记录扔掉"。
  /// 而数据一旦删掉没有回收站（插件表是 `DROP TABLE`），
  /// 所以破坏性的那个选项必须由用户主动勾选。
  Future<void> _confirmUninstall(
    BuildContext context,
    PluginMarketStore store,
    InstalledPlugin item,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final name = _nameOf(store, item.pluginId);
    var deleteData = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('卸载「$name」？', style: const TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '插件和它的入口会被移除，但相关数据仍保留。或————',
                style: TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: deleteData,
                onChanged: (value) =>
                    setDialogState(() => deleteData = value ?? false),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时删除它的数据', style: TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  '删除不可逆',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: const Text('卸载'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      await store.uninstall(item.pluginId, keepData: !deleteData);
      if (!mounted) return;
      // 说清楚到底删没删。不然用户下次装回来发现数据还在/没了，都会觉得奇怪
      _toast(deleteData ? '已卸载，数据已删除' : '已卸载，数据保留');
    } catch (_) {
      if (!mounted) return;
      _toast(store.lastError ?? '卸载失败');
      store.clearError();
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  static String _shortError(String? error) {
    if (error == null || error.isEmpty) return '已安装的插件不受影响';
    final oneLine = error.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 72 ? oneLine : '${oneLine.substring(0, 72)}…';
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({
    required this.title,
    required this.subtitle,
    required this.action,
    required this.seed,
    this.description,
    this.iconName,
  });

  final String title;
  final String subtitle;
  final String? description;
  final String? iconName;
  final Widget action;

  /// 用来挑图标底色，保证同一个插件每次颜色一样
  final String seed;

  static const List<Color> _palette = <Color>[
    Color(0xFF6750A4),
    Color(0xFF1D9E75),
    Color(0xFF185FA5),
    Color(0xFFBA7517),
    Color(0xFFD4537E),
  ];

  static IconData _iconFor(String? name) => switch (name) {
        'help' => Icons.help_outline,
        'timer' => Icons.timer_outlined,
        'stats' || 'bar_chart' => Icons.bar_chart,
        'palette' => Icons.palette_outlined,
        'shopping' || 'shop' => Icons.storefront_outlined,
        'bolt' => Icons.bolt,
        _ => Icons.extension_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 用 id 的稳定哈希选色：不能用 hashCode（不同进程可能不同）
    final tint = _palette[_stableHash(seed) % _palette.length];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_iconFor(iconName), size: 18, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                if (description != null && description!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.85)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          action,
        ],
      ),
    );
  }

  static int _stableHash(String value) {
    var hash = 0;
    for (final unit in value.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }
}

/// 停用 / 启用开关。
///
/// 尺寸压小是为了不把条目撑高、不把插件名挤窄 —— 条目里已经有两个按钮，
/// 再加一个默认尺寸的 Switch 会把标题压到只能显示两个字。
class _EnableSwitch extends StatelessWidget {
  const _EnableSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: value ? '停用' : '启用',
      child: SizedBox(
        width: 44,
        height: 30,
        child: Transform.scale(
          scale: 0.72,
          child: Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap, this.primary = false});

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: primary ? scheme.primary.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: primary ? scheme.primary.withValues(alpha: 0.35) : scheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: primary ? scheme.primary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        ),
        child: Text(label, style: TextStyle(fontSize: 11.5, color: scheme.error)),
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox({required this.icon, required this.text, required this.hint});

  final IconData icon;
  final String text;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 20, color: scheme.outline),
          const SizedBox(height: 8),
          Text(text, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(hint, style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }
}
