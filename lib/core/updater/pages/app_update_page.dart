import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_decision.dart';
import '../providers/app_update_provider.dart';
import '../services/app_update_launcher.dart';

/// 设置页里的「版本更新」入口。
///
/// 与自动弹窗互补：这里提供**手动检查**、查看更新说明，以及关掉大版本提醒的开关。
/// 检查结果与失败原因直接就地展示，不用 SnackBar，避免时序问题。
class AppUpdatePage extends StatelessWidget {
  const AppUpdatePage({super.key, this.title = '版本更新'});

  /// 标题。V5 从「设置」进来叫"版本更新"；V6 从「关于」进来，
  /// 页面里同时有版本号与更新入口，用"关于"更合界面语境。
  final String title;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppUpdateProvider>();
    final decision = provider.decision;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(title), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('当前版本'),
                  subtitle: Text(
                    provider.currentVersion.isEmpty
                        ? '读取中…'
                        : provider.currentVersion,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('检查更新'),
                  subtitle: Text(_statusText(provider)),
                  trailing: provider.isChecking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: () => provider.check(manual: true),
                          child: const Text('检查'),
                        ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('大版本更新提醒'),
                  subtitle: const Text('关闭后不再弹窗，仍可在本页手动检查'),
                  value: provider.notificationsEnabled,
                  onChanged: provider.setNotificationsEnabled,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.wifi_outlined),
                  title: const Text('仅 WiFi 自动下载'),
                  subtitle: const Text('移动网络下推迟资源更新包下载；手动点「立即更新」不受限'),
                  value: provider.wifiOnlyAutoDownload,
                  onChanged: provider.setWifiOnlyAutoDownload,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildStatsCard(context, provider, theme),
          if (decision.hasRelease) ...[
            const SizedBox(height: 16),
            _buildReleaseCard(context, provider, decision, theme),
          ],
          if (provider.hasUpdate && !decision.hasRelease) ...[
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('有资源更新待应用'),
                subtitle: Text('构建号 ${decision.assets?.build ?? 0}，将在下次启动前自动生效'),
              ),
            ),
          ],
          if (provider.message != null) ...[
            const SizedBox(height: 16),
            Text(
              provider.message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '说明：更新包从项目自己的 CDN 拉取并校验 sha256；'
            'Android 上会下载 APK 后交给系统安装器，首次需在系统设置里允许「安装未知应用」。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(AppUpdateProvider provider) {
    if (provider.isChecking) return '正在检查…';
    final decision = provider.decision;
    if (decision.kind == AppUpdateKind.forced) return '当前版本过旧，需要更新';
    if (decision.hasRelease) {
      return '发现新版本 ${decision.release!.version}';
    }
    return provider.currentVersion.isEmpty ? '—' : '已是最新版本';
  }

  Widget _buildStatsCard(
    BuildContext context,
    AppUpdateProvider provider,
    ThemeData theme,
  ) {
    final stats = provider.stats;
    final totalApp =
        stats.appSuccess + stats.appFailure + stats.appCancelled;
    final totalAsset = stats.assetSuccess + stats.assetFailure;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insights_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('更新统计', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (totalApp + totalAsset > 0)
                  TextButton(
                    onPressed: provider.resetStats,
                    child: const Text('清零'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (totalApp + totalAsset == 0)
              Text('本机暂无更新下载记录',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline))
            else ...[
              _statsLine(theme, '整包更新',
                  '成功 ${stats.appSuccess} · 失败 ${stats.appFailure} · 取消 ${stats.appCancelled}'),
              const SizedBox(height: 4),
              _statsLine(theme, '资源更新',
                  '成功 ${stats.assetSuccess} · 失败 ${stats.assetFailure}'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statsLine(ThemeData theme, String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          )),
        ),
      ],
    );
  }

  Widget _buildReleaseCard(
    BuildContext context,
    AppUpdateProvider provider,
    AppUpdateDecision decision,
    ThemeData theme,
  ) {
    final release = decision.release!;
    final forced = decision.kind == AppUpdateKind.forced;
    final notes = provider.releaseNotes;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  forced ? Icons.warning_amber : Icons.new_releases,
                  color: forced
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  forced ? '需要更新后才能继续使用' : '发现新版本 ${release.version}',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final note in notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('· $note'),
                ),
            ],
            if (provider.isApplying) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: provider.applyProgress),
              const SizedBox(height: 8),
              Text('下载中 ${(provider.applyProgress * 100).toStringAsFixed(0)}%'),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: provider.isApplying
                        ? provider.cancelApply
                        : () => _apply(context, provider),
                    child: Text(provider.isApplying ? '取消下载' : '立即更新'),
                  ),
                ),
                if (!forced) ...[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: provider.isApplying
                        ? null
                        : provider.ignoreCurrentVersion,
                    child: const Text('跳过此版本'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    AppUpdateProvider provider,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await provider.applyUpdate();
    switch (result) {
      case AppUpdateLaunchResult.installStarted:
        messenger.showSnackBar(
          const SnackBar(content: Text('安装包已下载，请在系统安装界面完成安装')),
        );
      case AppUpdateLaunchResult.openedDownloadPage:
        messenger.showSnackBar(const SnackBar(content: Text('已打开下载页')));
      case AppUpdateLaunchResult.failed:
        break;
    }
  }
}
