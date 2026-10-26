import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_decision.dart';
import '../providers/app_update_provider.dart';
import '../services/app_update_launcher.dart';

/// 弹出更新提示。
///
/// 强制更新时不可通过返回键或点击外部关闭——它存在的意义就是不让用户停留在
/// 不兼容的旧版本上；可选更新则允许「稍后」与「跳过此版本」。
Future<void> showAppUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AppUpdateDialog(),
  );
}

/// 更新提示弹窗本体。
class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppUpdateProvider>();
    final decision = provider.decision;
    final forced = decision.kind == AppUpdateKind.forced;
    final version = decision.release?.version ?? '';

    return PopScope(
      canPop: !forced,
      child: AlertDialog(
        title: Text(forced ? '需要更新后才能继续使用' : '发现新版本 $version'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本 ${provider.currentVersion}'
                '${version.isEmpty ? '' : '  →  $version'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (provider.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final note in provider.releaseNotes)
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
              if (provider.message != null) ...[
                const SizedBox(height: 12),
                Text(
                  provider.message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: _buildActions(context, provider, forced),
      ),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    AppUpdateProvider provider,
    bool forced,
  ) {
    final busy = provider.isApplying;
    if (forced) {
      return [
        FilledButton(
          onPressed: busy ? null : () => _apply(context, provider),
          child: Text(busy ? '下载中…' : '立即更新'),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: busy
            ? null
            : () {
                provider.dismissPrompt();
                Navigator.of(context).pop();
              },
        child: const Text('稍后'),
      ),
      TextButton(
        onPressed: busy
            ? null
            : () {
                provider.ignoreCurrentVersion();
                Navigator.of(context).pop();
              },
        child: const Text('跳过此版本'),
      ),
      FilledButton(
        onPressed: busy ? null : () => _apply(context, provider),
        child: Text(busy ? '下载中…' : '立即更新'),
      ),
    ];
  }

  Future<void> _apply(BuildContext context, AppUpdateProvider provider) async {
    // 弹窗关掉后 context 会失效，先把 messenger 取出来。
    final messenger = ScaffoldMessenger.of(context);
    final result = await provider.applyUpdate();
    if (!context.mounted) return;

    switch (result) {
      case AppUpdateLaunchResult.installStarted:
        Navigator.of(context).pop();
        messenger.showSnackBar(
          const SnackBar(content: Text('安装包已下载，请在系统安装界面完成安装')),
        );
      case AppUpdateLaunchResult.openedDownloadPage:
        Navigator.of(context).pop();
        messenger.showSnackBar(
          const SnackBar(content: Text('已打开下载页')),
        );
      case AppUpdateLaunchResult.failed:
        // 失败原因已写进 provider.message，弹窗内容会自动刷新显示。
        break;
    }
  }
}

/// 挂在应用根部的宿主：当 provider 判定需要弹窗时自动弹出一次。
///
/// 之所以不直接写在页面里，是因为「冷启动检查到主版本更新」这件事与具体页面无关；
/// 放在根部可以保证无论用户停在哪个页面都能收到提示。
class AppUpdatePromptHost extends StatefulWidget {
  const AppUpdatePromptHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdatePromptHost> createState() => _AppUpdatePromptHostState();
}

class _AppUpdatePromptHostState extends State<AppUpdatePromptHost>
    with WidgetsBindingObserver {
  AppUpdateProvider? _provider;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<AppUpdateProvider>();
    if (identical(provider, _provider)) return;
    _provider?.removeListener(_maybeShow);
    _provider = provider..addListener(_maybeShow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _provider?.removeListener(_maybeShow);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台时顺带检查一次；provider 内部会按间隔节流，不会真的每次都联网。
    if (state == AppLifecycleState.resumed) {
      _provider?.checkIfDue();
    }
  }

  void _maybeShow() {
    if (!mounted || _showing) return;
    final provider = _provider;
    if (provider == null || !provider.promptPending) return;

    _showing = true;
    showAppUpdateDialog(context).whenComplete(() {
      _showing = false;
      // 用户可能通过「稍后」以外的方式关掉（强制更新除外），统一标记为已提示。
      provider.dismissPrompt();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
