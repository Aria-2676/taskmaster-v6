import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 拉取远端文本（更新清单、插件索引都用它）。
///
/// 之所以单独抽出来：GitHub Contents API 的返回是个信封，`content` 是 base64，
/// 而且**按 76 列插了换行**，解码前必须剥掉。这段逻辑复制到第二处，
/// 早晚有一边忘了剥 —— 表现是"某个源拿到一串乱码"，还只在兜底路径上出现。
class RemoteText {
  const RemoteText._();

  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 拉一个地址。
  ///
  /// [viaContentsApi] 为 true 时按 GitHub Contents API 的 JSON 信封解包。
  static Future<String> fetch(
    Uri uri, {
    required bool viaContentsApi,
    Duration timeout = defaultTimeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      // CDN 与 raw 都会缓存；插件货架"发了就该看到"，所以每次都要求最新。
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set('Pragma', 'no-cache');
      if (viaContentsApi) {
        request.headers.set('Accept', 'application/vnd.github+json');
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw RemoteTextException('HTTP ${response.statusCode}');
      }
      final rawBody = await response.transform(utf8.decoder).join().timeout(timeout);
      if (!viaContentsApi) return rawBody;

      final envelope = jsonDecode(rawBody);
      if (envelope is! Map ||
          envelope['encoding']?.toString() != 'base64' ||
          envelope['content'] is! String) {
        throw const RemoteTextException('Contents API 响应结构异常');
      }
      final compact = (envelope['content'] as String).replaceAll(RegExp(r'\s'), '');
      return utf8.decode(base64.decode(compact));
    } on RemoteTextException {
      rethrow;
    } catch (error) {
      throw RemoteTextException('$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 并发拉所有源，**挑"最新"的那份**。
  ///
  /// [freshnessOf] 从响应体里读时间戳（读不出来就返回 epoch，视为最旧）。
  ///
  /// 为什么不能"第一个成功就用"：CDN 会缓存分支解析出来的那个提交（实测
  /// jsDelivr 的 gcore 节点会持续发旧文件，purge 也刷不掉），而"最快响应的
  /// 那个"完全可能是"最旧的那个"。更新清单和插件索引都栽过这个坑。
  static Future<String> fetchNewest(
    List<Uri> candidates, {
    Uri? contentsApi,
    required DateTime Function(String body) freshnessOf,
    Duration timeout = defaultTimeout,
    Duration grace = const Duration(milliseconds: 600),
    RemoteTextFetcher? fetch,
    void Function(Uri uri, Object error)? onFailure,
  }) async {
    final doFetch = fetch ??
        (Uri uri, {required bool viaContentsApi, required Duration timeout}) =>
            RemoteText.fetch(uri, viaContentsApi: viaContentsApi, timeout: timeout);

    final sources = <(Uri, bool)>[
      for (final candidate in candidates) (candidate, false),
      if (contentsApi != null) (contentsApi, true),
    ];
    if (sources.isEmpty) throw const RemoteTextException('没有可用的地址');

    final arrived = <String>[];
    final firstOk = Completer<void>();
    final allDone = Completer<void>();
    var left = sources.length;

    for (final (uri, viaApi) in sources) {
      unawaited(() async {
        try {
          final body = await doFetch(uri, viaContentsApi: viaApi, timeout: timeout);
          arrived.add(body);
          if (!firstOk.isCompleted) firstOk.complete();
        } catch (error) {
          onFailure?.call(uri, error);
        } finally {
          left--;
          if (left == 0 && !allDone.isCompleted) allDone.complete();
        }
      }());
    }

    // 等到"至少一个成功"或"全部结束"，再多等一小会儿收齐其它源 ——
    // 否则拿到的只是"响应最快的"，不等于"最新的"。
    await Future.any<void>(<Future<void>>[firstOk.future, allDone.future]);
    await Future.any<void>(<Future<void>>[
      allDone.future,
      Future<void>.delayed(grace),
    ]);

    if (arrived.isEmpty) {
      throw const RemoteTextException('所有源都失败了');
    }
    return arrived.reduce((a, b) => freshnessOf(b).isAfter(freshnessOf(a)) ? b : a);
  }

  /// 依次尝试 [candidates]，全挂再用 [contentsApi] 兜底。
  ///
  /// **单个源失败只记一笔并继续**：某个 CDN 节点抽风不该让整个功能不可用。
  /// 全部失败才抛，异常里带最后一条错误，方便界面把原文露出来。
  static Future<String> fetchFromCandidates(
    List<Uri> candidates, {
    Uri? contentsApi,
    Duration timeout = defaultTimeout,
    void Function(Uri uri, Object error)? onFailure,
  }) async {
    Object? lastError;
    for (final uri in candidates) {
      try {
        return await fetch(uri, viaContentsApi: false, timeout: timeout);
      } catch (error) {
        lastError = error;
        onFailure?.call(uri, error);
      }
    }
    if (contentsApi != null) {
      try {
        return await fetch(contentsApi, viaContentsApi: true, timeout: timeout);
      } catch (error) {
        lastError = error;
        onFailure?.call(contentsApi, error);
      }
    }
    throw RemoteTextException('所有源都失败了（最后一个：$lastError）');
  }
}

class RemoteTextException implements Exception {
  const RemoteTextException(this.message);

  final String message;

  @override
  String toString() => 'RemoteTextException: $message';
}

/// 拉一份文本。抽成 typedef 是为了让"并发取最新"这段能单测（不真联网）。
typedef RemoteTextFetcher = Future<String> Function(
  Uri uri, {
  required bool viaContentsApi,
  required Duration timeout,
});
