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
