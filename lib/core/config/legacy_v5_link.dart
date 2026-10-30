import '../updater/models/app_update_manifest.dart';

/// 旧版（V5）的下载信息与通道。
///
/// 为什么给多个通道而不是一个 GitHub 直链：GitHub 的 release 资产在国内经常
/// 下不动（域名叫得上，`objects.githubusercontent.com` 拿不到）。用户点一下跳出去
/// 却什么都下不到，比不给入口更糟。
///
/// 主路径**走更新器**（下载 → 校验 sha256 → 交给系统安装器），和 V6 自己升级
/// 用同一条管道：有进度、有镜像回退、有摘要校验。手动通道只作为兜底。
///
/// 包名不同（`com.noteapp.taskmaster` vs `.v6`），所以系统会把 5.5.26 当成
/// **另一个 App** 安装，不会覆盖 V6 —— 这也是"两个能共存"的前提。
class LegacyV5Link {
  const LegacyV5Link._();

  static const String version = '5.5.26';

  /// V5 的最后一个整包（fat APK，任何机型都能装）
  static const String apkUrl =
      'https://github.com/Aria-2676/note_study/releases/download/v5.5.26/app-release.apk';

  /// 出问题时可以让人自己去挑（分 ABI 的包更小）
  static const String releasesUrl = 'https://github.com/Aria-2676/note_study/releases';

  /// 与 GitHub release 上那份资产逐字节一致的摘要与体积（2026-10-30 从 API 读的）。
  /// 写死是有意的：代理是不可信的，下载完必须能校验，否则宁可报错也别装。
  static const String sha256 = '388ad0a727eac76d0e40baeffb328dfd48ace1d3b902c46af38579139c17ab2f';
  static const int sizeBytes = 64751273;

  /// 公共 GitHub 代理前缀（和更新器用的是同一批，见 update.json 的 mirrors）
  static const List<String> proxyPrefixes = <String>[
    'https://ghfast.top',
    'https://gh-proxy.com',
  ];

  /// 交给更新器去下载安装的目标
  static AppDownloadTarget get target => AppDownloadTarget(
        url: apkUrl,
        mirrors: <String>[for (final prefix in proxyPrefixes) '$prefix/$apkUrl'],
        sha256: sha256,
        sizeBytes: sizeBytes,
      );

  /// 自动路径失败时，让用户自己挑一个通道
  static List<LegacyChannel> get channels => <LegacyChannel>[
        const LegacyChannel(label: 'GitHub（原始地址）', url: apkUrl, note: '国外或能直连时最快'),
        for (final prefix in proxyPrefixes)
          LegacyChannel(
            label: '国内代理 · ${Uri.parse(prefix).host}',
            url: '$prefix/$apkUrl',
            note: '公共代理，能用但随时可能失效',
          ),
        const LegacyChannel(label: '打不开就去 release 页自己挑', url: releasesUrl, note: '分机型的包更小'),
      ];

  /// 兜底界面上要如实说的一句：这些都不是长期保证
  static const String stableHint = '以上都是 GitHub 或其公共代理。要长期稳定，得把安装包放到国内的托管上。';
}

class LegacyChannel {
  const LegacyChannel({required this.label, required this.url, this.note});

  final String label;
  final String url;
  final String? note;
}
