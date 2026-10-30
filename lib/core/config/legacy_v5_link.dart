import '../updater/models/app_update_manifest.dart';

/// 一个可下载的产物。
class V5Artifact {
  const V5Artifact({
    required this.file,
    required this.sha256,
    required this.sizeBytes,
  });

  /// Release 里的文件名，也是 URL 的最后一段。
  final String file;
  final String sha256;
  final int sizeBytes;

  double get megabytes => sizeBytes / 1024 / 1024;
}

/// 旧版（V5）的下载信息与通道。
///
/// 为什么给多个通道而不是一个 GitHub 直链：GitHub 的 release 资产在国内经常
/// 下不动（域名叫得上，`objects.githubusercontent.com` 拿不到）。用户点一下跳出去
/// 却什么都下不到，比不给入口更糟。
///
/// 主路径**走更新器**（下载 → 校验 sha256 → 交给系统安装器），和 V6 自己升级
/// 用同一条管道：有进度、有镜像回退、有摘要校验。手动通道只作为兜底。
///
/// 包名不同（`com.noteapp.taskmaster` vs `.v6`），所以系统会把 5.5.28 当成
/// **另一个 App** 安装，不会覆盖 V6 —— 这也是"两个能共存"的前提。
///
/// 指向 5.5.28：它带「下载 6.x」的固定入口、按机型选包（arm64 只 21MB），
/// 也修掉了更新器"只取第一个响应的源"的毛病。两边互相指路才闭合 ——
/// V5 里能下 6.x，6.x 里能回 V5。
///
/// **按机型选包**：5.5.28 有分架构的产物，arm64 只有 23MB，通用整包 62MB。
class LegacyV5Link {
  const LegacyV5Link._();

  static const String version = '5.5.28';

  static const String _giteeBase =
      'https://gitee.com/yaozhenqian/taskmaster-release/releases/download/v5.5.28';

  static const String _githubBase =
      'https://github.com/Aria-2676/note_study/releases/download/v5.5.28';

  /// 分架构产物。键与 Flutter `--split-per-abi` 的后缀（也是 `getprop` 的取值）一致。
  ///
  /// sha256 是各包**各自**的 —— 不能拿整包那个去校验分架构包，会直接报摘要不符。
  static const Map<String, V5Artifact> artifacts = <String, V5Artifact>{
    'arm64-v8a': V5Artifact(
      file: 'app-arm64-v8a-release.apk',
      sha256: '2a721522d060363cd20b7c4d811f2a3b9e15cbbf02e98aa953599785612b4269',
      sizeBytes: 23900863,
    ),
    'armeabi-v7a': V5Artifact(
      file: 'app-armeabi-v7a-release.apk',
      sha256: 'e3bf091a4de8f6d48db9c45d9d1913b096656586c717913f8fcc5281aed26052',
      sizeBytes: 21637259,
    ),
    'x86_64': V5Artifact(
      file: 'app-x86_64-release.apk',
      sha256: '214e28605b1e7a67982df8ef72272a641e30612993018745cbfda0e877a0527a',
      sizeBytes: 25384635,
    ),
  };

  /// 通用整包：任何机型都能装，代价是 62MB。只在拿不到 ABI 时用。
  static const V5Artifact fallback = V5Artifact(
    file: 'app-release.apk',
    sha256: '83604c5c09245af703a61030d90c7bd5dec1ba5e1002f6e5d1a4d9b9c81a2b60',
    sizeBytes: 64821537,
  );

  /// 出问题时可以让人自己去挑
  static const String releasesUrl = 'https://github.com/Aria-2676/note_study/releases';

  /// 公共 GitHub 代理前缀（和更新器用的是同一批，见 update.json 的 mirrors）
  static const List<String> proxyPrefixes = <String>[
    'https://ghfast.top',
    'https://gh-proxy.com',
  ];

  static V5Artifact artifactFor(String? abi) => artifacts[abi] ?? fallback;

  /// 交给更新器去下载安装的目标：Gitee 主源 → GitHub → 两个公共代理
  static AppDownloadTarget targetFor(String? abi) {
    final artifact = artifactFor(abi);
    final githubUrl = '$_githubBase/${artifact.file}';
    return AppDownloadTarget(
      url: '$_giteeBase/${artifact.file}',
      mirrors: <String>[
        githubUrl,
        for (final prefix in proxyPrefixes) '$prefix/$githubUrl',
      ],
      sha256: artifact.sha256,
      sizeBytes: artifact.sizeBytes,
    );
  }

  /// 确认框里的体积说明
  static String sizeLabelFor(String? abi) =>
      '约 ${artifactFor(abi).megabytes.toStringAsFixed(0)} MB';

  /// 自动路径失败时，让用户自己挑一个通道
  static List<LegacyChannel> channelsFor(String? abi) {
    final artifact = artifactFor(abi);
    final giteeUrl = '$_giteeBase/${artifact.file}';
    final githubUrl = '$_githubBase/${artifact.file}';
    return <LegacyChannel>[
      LegacyChannel(label: 'Gitee（国内推荐）', url: giteeUrl, note: '国内直连可用'),
      LegacyChannel(
        label: 'GitHub（原始地址）',
        url: githubUrl,
        note: '国外或能直连时最快',
      ),
      for (final prefix in proxyPrefixes)
        LegacyChannel(
          label: '国内代理 · ${Uri.parse(prefix).host}',
          url: '$prefix/$githubUrl',
          note: '公共代理，能用但随时可能失效',
        ),
      const LegacyChannel(
        label: '打不开就去 release 页自己挑',
        url: releasesUrl,
        note: '分机型的包更小',
      ),
    ];
  }

  /// 兜底界面上要如实说的一句
  static const String stableHint =
      'Gitee 排第一（国内直连），后面是 GitHub 与公共代理；下载完都会校验摘要。';
}

class LegacyChannel {
  const LegacyChannel({required this.label, required this.url, this.note});

  final String label;
  final String url;
  final String? note;
}
