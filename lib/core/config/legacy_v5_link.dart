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
/// 包名不同（`com.noteapp.taskmaster` vs `.v6`），所以系统会把 5.5.27 当成
/// **另一个 App** 安装，不会覆盖 V6 —— 这也是"两个能共存"的前提。
///
/// 指向 5.5.27 而不是 5.5.26：那个版本才带「下载 6.x」的固定入口，也修掉了
/// 更新器"只取第一个响应的源"的毛病。两边互相指路才闭合 —— V5 里能下 6.x，
/// 6.x 里能回 V5。
class LegacyV5Link {
  const LegacyV5Link._();

  static const String version = '5.5.27';

  /// V5 的最后一个整包（fat APK，任何机型都能装）。
  ///
  /// 主地址用 **Gitee**：国内直连可用，GitHub 经常下不动。两个地址的字节完全一致
  /// （sha256 都是 [sha256]），所以备用源换哪个都不影响校验。
  static const String apkUrl =
      'https://gitee.com/yaozhenqian/taskmaster-release/releases/download/v5.5.27/app-release.apk';

  /// GitHub 原链（国外用户更快）
  static const String apkUrlGithub =
      'https://github.com/Aria-2676/note_study/releases/download/v5.5.27/app-release.apk';

  /// 出问题时可以让人自己去挑（分 ABI 的包更小）
  static const String releasesUrl = 'https://github.com/Aria-2676/note_study/releases';

  /// 与 GitHub / Gitee 两份资产逐字节一致的摘要与体积（2026-10-30 的 5.5.27 构建）。
  /// 写死是有意的：代理是不可信的，下载完必须能校验，否则宁可报错也别装。
  static const String sha256 = 'e68b47f0f571d3c724c6fddd0e93d7a1a6c3fc0f051cbcf7d625fe55304cbc36';
  static const int sizeBytes = 64821537;

  /// 公共 GitHub 代理前缀（和更新器用的是同一批，见 update.json 的 mirrors）
  static const List<String> proxyPrefixes = <String>[
    'https://ghfast.top',
    'https://gh-proxy.com',
  ];

  /// 交给更新器去下载安装的目标：Gitee 主源 → GitHub → 两个公共代理
  static AppDownloadTarget get target => AppDownloadTarget(
        url: apkUrl,
        mirrors: <String>[
          apkUrlGithub,
          for (final prefix in proxyPrefixes) '$prefix/$apkUrlGithub',
        ],
        sha256: sha256,
        sizeBytes: sizeBytes,
      );

  /// 自动路径失败时，让用户自己挑一个通道
  static List<LegacyChannel> get channels => <LegacyChannel>[
        const LegacyChannel(label: 'Gitee（国内推荐）', url: apkUrl, note: '国内直连可用'),
        const LegacyChannel(label: 'GitHub（原始地址）', url: apkUrlGithub, note: '国外或能直连时最快'),
        for (final prefix in proxyPrefixes)
          LegacyChannel(
            label: '国内代理 · ${Uri.parse(prefix).host}',
            url: '$prefix/$apkUrlGithub',
            note: '公共代理，能用但随时可能失效',
          ),
        const LegacyChannel(label: '打不开就去 release 页自己挑', url: releasesUrl, note: '分机型的包更小'),
      ];

  /// 兜底界面上要如实说的一句：这些都不是长期保证
  static const String stableHint = 'Gitee 排第一（国内直连），后面是 GitHub 与公共代理；下载完都会校验摘要。';
}

class LegacyChannel {
  const LegacyChannel({required this.label, required this.url, this.note});

  final String label;
  final String url;
  final String? note;
}
