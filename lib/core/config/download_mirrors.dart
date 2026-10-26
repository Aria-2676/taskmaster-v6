/// APK 下载源扩展策略。
///
/// 背景：App 更新包托管在 GitHub Releases。它的下载地址
/// (`github.com/.../releases/download/...`) 会 302 到
/// `objects.githubusercontent.com`，这两个主机在国内都可能长时间不可达，
/// 表现为「下载失败/一直转圈」。
///
/// 公益 GitHub 加速站（反代整个 github.com）在国内可达性高得多，
/// 用法只是在原 URL 前拼前缀，例如：
/// `https://gh-proxy.com/https://github.com/owner/repo/releases/download/v/x.apk`。
/// 反代并非可信信道，但下载产物有 sha256 端到端校验（见 [FileDownloader] /
/// `AppUpdateLauncher`），内容被篡改会被直接拒绝，所以多一路源只增可用性、
/// 不降安全性。
///
/// 列表写在代码里只是**兜底**：清单的 `mirrors` 字段可以随时下发新镜像，
/// 应对某个公益站突然关停——老客户端即使不升级也能通过新镜像下载。
class DownloadMirrors {
  const DownloadMirrors._();

  /// 内置 GitHub 加速前缀（末尾不带 `/`）。
  ///
  /// 仅收录实测可用的站点；失效站点不要保留，避免每个用户都先等一轮超时。
  /// 顺序也是实测排的：2026-10-15 同网环境下 ghfast.top 整包 24MB 下载成功
  /// 且 sha256 校验通过，gh-proxy.com 探活正常但大文件吞吐近乎停滞
  /// （5 分钟未完成），故 ghfast 排第一。清单 `mirrors` 字段可热下发，
  /// 不必发版即可调整这个顺序。
  static const List<String> githubProxyPrefixes = [
    'https://ghfast.top',
    'https://gh-proxy.com',
  ];

  /// 匹配 GitHub Release 资产地址：
  /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`
  static final RegExp _githubReleaseUrl = RegExp(
    r'^https?://github\.com/[^/]+/[^/]+/releases/download/.+$',
    caseSensitive: false,
  );

  /// 展开一个下载地址为「按尝试顺序排列」的候选列表。
  ///
  /// 顺序：
  /// 1. 清单显式声明的 [explicitMirrors]（运维可随时下发，**优先级最高**，
  ///    这样镜像挂了不必等 App 升级）；
  /// 2. 内置公益加速镜像（仅对 GitHub Releases 地址生效）；
  /// 3. 原始地址（直连 GitHub）兜底。
  ///
  /// 之所以直连放最后：本机实测 github.com 在国内可能连续数小时不可达，
  /// 先直连会让每个用户白等一轮连接超时。sha256 校验保证换源不降安全性。
  ///
  /// 自动去重（大小写归一 + 结尾斜杠归一），同一源不会被尝试两次。
  static List<String> expand(
    String primary, {
    List<String> explicitMirrors = const [],
    List<String> proxyPrefixes = githubProxyPrefixes,
  }) {
    final ordered = <String>[
      ...explicitMirrors.map(_normalize).where((s) => s.isNotEmpty),
    ];

    if (_githubReleaseUrl.hasMatch(primary.trim())) {
      for (final prefix in proxyPrefixes) {
        ordered.add('${_normalizeBase(prefix)}/${primary.trim()}');
      }
    }

    ordered.add(primary.trim());
    return _dedupe(ordered);
  }

  static String _normalize(String url) => url.trim();

  static String _normalizeBase(String prefix) {
    final t = prefix.trim();
    return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
  }

  static List<String> _dedupe(List<String> urls) {
    final seen = <String>{};
    final result = <String>[];
    for (final url in urls) {
      // 归一化只用于去重判断：去结尾斜杠、host 小写。
      final key = _dedupeKey(url);
      if (seen.add(key)) result.add(url);
    }
    return result;
  }

  static String _dedupeKey(String url) {
    final noSlash = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final uri = Uri.tryParse(noSlash);
    if (uri == null) return noSlash.toLowerCase();
    return uri.replace(scheme: uri.scheme.toLowerCase()).toString().toLowerCase();
  }
}
