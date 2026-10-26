import 'package:flutter_test/flutter_test.dart';
import 'package:v5_app/core/config/download_mirrors.dart';

void main() {
  const gh =
      'https://github.com/owner/repo/releases/download/v1.0.0/app.apk';

  group('DownloadMirrors.expand GitHub Release 地址', () {
    test('展开顺序：内置镜像在前、直连在最后', () {
      final list = DownloadMirrors.expand(gh);
      expect(list, [
        'https://ghfast.top/$gh',
        'https://gh-proxy.com/$gh',
        gh,
      ]);
    });

    test('scheme/host 大小写不影响识别，但保留原始 URL 形态', () {
      const upper = 'HTTPS://GitHub.COM/owner/repo/releases/download/v/a.apk';
      final list = DownloadMirrors.expand(upper);
      expect(list.first, 'https://ghfast.top/$upper');
      expect(list.last, upper);
    });

    test('非标准端口/深层路径只要符合形态也识别', () {
      const url =
          'http://github.com/owner/repo/releases/download/v1/x/y/app.apk';
      final list = DownloadMirrors.expand(url, proxyPrefixes: ['https://p/']);
      expect(list, ['https://p/$url', url]);
    });
  });

  group('DownloadMirrors.expand 非 GitHub 地址', () {
    test('普通 https 地址不加镜像前缀，只返回自身', () {
      const url = 'https://example.com/files/app.apk';
      expect(DownloadMirrors.expand(url), [url]);
    });

    test('github.com 但不是 releases/download 路径，不加前缀', () {
      const url = 'https://github.com/owner/repo/raw/main/update.json';
      expect(DownloadMirrors.expand(gh), isNot(contains(url)));
      expect(DownloadMirrors.expand(url), [url]);
    });

    test('显式镜像对非 GitHub 地址仍然生效（运维源可自由指定）', () {
      const url = 'https://example.com/app.apk';
      const m1 = 'https://mirror-a.example.com/app.apk';
      final list = DownloadMirrors.expand(url, explicitMirrors: [m1]);
      expect(list, [m1, url]);
    });
  });

  group('DownloadMirrors.expand 显式 mirrors', () {
    test('显式镜像排在最前', () {
      const hot = 'https://hot-mirror.example.com/app.apk';
      final list = DownloadMirrors.expand(gh, explicitMirrors: [hot]);
      expect(list.first, hot);
      expect(list, containsAll([
        'https://gh-proxy.com/$gh',
        'https://ghfast.top/$gh',
        gh,
      ]));
      expect(list.length, 4);
    });

    test('空白镜像条目被丢弃', () {
      final list = DownloadMirrors.expand(gh, explicitMirrors: ['  ', '']);
      expect(list, [
        'https://ghfast.top/$gh',
        'https://gh-proxy.com/$gh',
        gh,
      ]);
    });
  });

  group('DownloadMirrors.expand 去重', () {
    test('显式镜像与内置镜像同址时只保留第一次出现（显式优先）', () {
      final list = DownloadMirrors.expand(
        gh,
        explicitMirrors: ['https://gh-proxy.com/$gh'],
      );
      expect(list.first, 'https://gh-proxy.com/$gh');
      expect(
        list.where((u) => u == 'https://gh-proxy.com/$gh').length,
        1,
      );
      expect(list.last, gh);
    });

    test('结尾斜杠差异视为同一源，保留首次出现的形态', () {
      const slashed = 'https://gh-proxy.com/$gh/';
      final list = DownloadMirrors.expand(
        gh,
        explicitMirrors: [slashed],
      );
      // 显式镜像（带斜杠形态）在第一位，内置的同址无斜杠版本被去重。
      expect(list.first, slashed);
      expect(list.contains('https://gh-proxy.com/$gh'), isFalse);
      expect(list.where((u) => u.replaceAll(RegExp(r'/$'), '') ==
          'https://gh-proxy.com/$gh').length, 1);
    });

    test('前缀自带结尾斜杠时不会拼出双斜杠', () {
      final list = DownloadMirrors.expand(
        gh,
        proxyPrefixes: ['https://p.example/'],
      );
      expect(list.first, 'https://p.example/$gh');
    });

    test('原始地址重复出现在显式镜像里时只尝试一次', () {
      final list = DownloadMirrors.expand(gh, explicitMirrors: [gh]);
      expect(list.where((u) => u == gh).length, 1);
      // 首次出现的位置（显式声明位）被保留。
      expect(list.first, gh);
    });
  });
}
