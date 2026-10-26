/// 内容分发的共用基址。
///
/// 游戏包（`game_center/`）与 App 更新包（`releases/`）托管在同一个 GitHub 仓库、
/// 走同一批 CDN 镜像，所以基址集中在这里维护，避免两处各写一份、改名时漏改。
///
/// 可用 `--dart-define` 在构建时覆盖。**沿用既有的环境变量名**，这样已有的构建
/// 脚本与文档不需要改动：
/// ```powershell
/// flutter build apk --dart-define=GAME_CDN_BASE=https://example.com/base
/// ```
class CdnBases {
  const CdnBases._();

  /// 小文件（清单类，如 manifest.json / update.json）的基址。
  ///
  /// 默认走 jsDelivr 的 GCore 节点：2026-10 实测 `cdn.jsdelivr.net` 在本机
  /// 连接被重置、而 `gcore` / `testingcf` 稳定，故主站用 gcore，把 cdn
  /// 放进回退列表。jsDelivr 对分支引用有约 12 小时缓存，发布后由发布脚本
  /// 主动调 purge API 清缓存，客户端侧则另有 raw / GitHub API 两个近实时源。
  static const String manifest = String.fromEnvironment(
    'GAME_CDN_BASE',
    defaultValue: 'https://gcore.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
  );

  /// 大文件（游戏包、App 更新包）的基址。
  ///
  /// 刻意**不用** `cdn.jsdelivr.net` 作为首选：实测它对 `.zip` / `.apk` 会 301
  /// 重定向到 `raw.githubusercontent.com`（该主机在国内常被间歇性 reset），
  /// 而 `gcore.jsdelivr.net` / `testingcf.jsdelivr.net` 可直连返回 200。
  ///
  /// 发布时仍可注入 commit SHA（`...@<sha>`），使同一路径的内容永久不变，
  /// 从而让 sha256 校验真正具备意义。
  static const String largeFile = String.fromEnvironment(
    'GAME_CDN_SHA_BASE',
    defaultValue: 'https://gcore.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
  );

  /// 清单类文件的回退基址（按顺序尝试）。
  ///
  /// 主站 gcore 之外的 jsDelivr 节点在前；`raw.githubusercontent.com`
  /// 虽 TCP 可连、HTTP 却曾常被中途重置，故置末位兜底。
  /// App 更新清单还另有 GitHub Contents API 一路（见 AppUpdateService），
  /// 游戏清单不走那条，因此不放进这里。
  static const List<String> manifestFallbacks = [
    'https://testingcf.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
    'https://cdn.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
    'https://raw.githubusercontent.com/Aria-2676/taskmaster-v6/main',
  ];

  /// 大文件的回退基址（按顺序尝试）。
  ///
  /// 各 jsDelivr 镜像对 `@main` 的缓存彼此独立，且 `purge.jsdelivr.net` 只覆盖
  /// CF/FY 两个 provider，无法清理 `gcore` / `testingcf`。因此同一路径在不同
  /// 镜像上可能新旧不一：清单已更新、包却仍是旧版，导致 sha256 校验失败。
  /// 下载时若校验不通过，依次回退到其它镜像，最后落到不受 CDN 缓存影响的源站。
  static const List<String> largeFileFallbacks = [
    'https://testingcf.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
    'https://cdn.jsdelivr.net/gh/Aria-2676/taskmaster-v6@main',
    'https://raw.githubusercontent.com/Aria-2676/taskmaster-v6/main',
  ];

  /// 按顺序拼出候选地址：主基址在前，回退基址在后，并自动去重。
  ///
  /// 主基址可能与回退列表里的某一项重复（例如两者都指向 `gcore`），
  /// 用 [Set] 去重可避免同一个源被连续尝试两次。
  static List<Uri> resolve(
    String primary,
    List<String> fallbacks,
    String relativePath,
  ) {
    final bases = <String>{primary, ...fallbacks};
    return bases.map((base) => Uri.parse('$base/$relativePath')).toList();
  }
}
