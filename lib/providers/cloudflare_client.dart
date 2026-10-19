import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../core/gen_types.dart';

/// Talks to our own Cloudflare Worker relay (see worker/ in the repo), which
/// runs @cf/black-forest-labs/flux-1-schnell. No Cloudflare token lives in
/// the app; the Worker checks a shared secret header (a light deterrent only).
class CloudflareClient implements ImageGenerator {
  static const model = '@cf/black-forest-labs/flux-1-schnell';
  static const secretHeader = 'X-App-Secret';

  final http.Client _http;
  final String workerUrl;
  final String sharedSecret;
  final Duration timeout;

  CloudflareClient(this._http,
      {required this.workerUrl,
      required this.sharedSecret,
      this.timeout = const Duration(seconds: 60)});

  @override
  ProviderId get id => ProviderId.cloudflare;

  @override
  bool get isConfigured => normalizeBase(workerUrl) != null;

  /// Accepts "my-worker.x.workers.dev", "https://.../" or ".../generate".
  static Uri? normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    var path = u.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (path.endsWith('/generate')) path = path.substring(0, path.length - 9);
    return u.replace(path: path, query: null, fragment: null);
  }

  Uri get generateUri {
    final b = normalizeBase(workerUrl)!;
    return b.replace(path: '${b.path}/generate');
  }

  Uri get healthUri {
    final b = normalizeBase(workerUrl)!;
    return b.replace(path: '${b.path}/health');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (sharedSecret.isNotEmpty) secretHeader: sharedSecret,
      };

  static Map<String, dynamic> buildBody(GenRequest req) => {
        'prompt': req.prompt,
        'steps': req.steps.clamp(1, 8),
        'seed': req.seed,
      };

  @override
  Future<GenImage> generate(GenRequest req) async {
    if (!isConfigured) {
      throw GenException(GenErrorCode.notConfigured, 'No Worker URL set', provider: id);
    }
    http.Response res;
    try {
      res = await _http
          .post(generateUri, headers: _headers, body: jsonEncode(buildBody(req)))
          .timeout(timeout);
    } on TimeoutException {
      throw GenException(GenErrorCode.timeout, 'No answer in ${timeout.inSeconds}s',
          provider: id);
    } on SocketException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    } on http.ClientException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    }
    return parseResponse(res, req);
  }

  /// Returns null if healthy, otherwise an error message.
  Future<String?> checkHealth() async {
    if (!isConfigured) return 'No Worker URL set';
    try {
      final r = await _http.get(healthUri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) return null;
      final e = _errorFrom(r);
      return e.friendly;
    } catch (e) {
      return 'Could not reach the Worker: $e';
    }
  }

  GenImage parseResponse(http.Response res, GenRequest req) {
    final ct = res.headers['content-type'] ?? '';
    if (res.statusCode == 200) {
      if (ct.startsWith('image/') && looksLikeImage(res.bodyBytes)) {
        return GenImage(
            bytes: res.bodyBytes,
            mime: sniffMime(res.bodyBytes),
            provider: id,
            model: model,
            seed: req.seed);
      }
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        var b64 = (j['image'] ?? '') as String;
        final comma = b64.indexOf(',');
        if (b64.startsWith('data:') && comma > 0) b64 = b64.substring(comma + 1);
        final bytes = base64Decode(b64);
        if (!looksLikeImage(bytes)) throw const FormatException('not an image');
        return GenImage(
          bytes: bytes,
          mime: sniffMime(bytes),
          provider: id,
          model: (j['model'] as String?) ?? model,
          seed: (j['seed'] as num?)?.toInt() ?? req.seed,
        );
      } catch (e) {
        throw GenException(GenErrorCode.server, 'Bad response from Worker: $e',
            provider: id, httpStatus: 200);
      }
    }
    throw _errorFrom(res);
  }

  GenException _errorFrom(http.Response res) {
    final s = res.statusCode;
    String code = '';
    String msg = 'HTTP $s';
    int? retry;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        code = (err['code'] ?? '').toString();
        msg = (err['message'] ?? msg).toString();
        retry = (err['retryAfter'] as num?)?.toInt();
      }
    } catch (_) {}
    final ra = retry != null
        ? Duration(seconds: retry)
        : parseRetryAfter(res.headers['retry-after']);
    final mapped = mapErrorCode(code, s);
    return GenException(mapped, msg, provider: id, retryAfter: ra, httpStatus: s);
  }

  /// Worker error code (or bare HTTP status) -> app error code.
  static GenErrorCode mapErrorCode(String code, int status) {
    switch (code) {
      case 'quota':
        return GenErrorCode.quota;
      case 'rate_limited':
        return GenErrorCode.rateLimited;
      case 'unauthorized':
        return GenErrorCode.auth;
      case 'bad_request':
        return GenErrorCode.badRequest;
      case 'content_filtered':
        return GenErrorCode.contentFiltered;
      case 'upstream_timeout':
        return GenErrorCode.timeout;
      case 'upstream':
      case 'internal':
        return GenErrorCode.server;
    }
    if (status == 401 || status == 403) return GenErrorCode.auth;
    if (status == 429) return GenErrorCode.rateLimited;
    if (status == 400 || status == 413 || status == 422) return GenErrorCode.badRequest;
    if (status == 504) return GenErrorCode.timeout;
    if (status == 404) return GenErrorCode.notConfigured;
    if (status >= 500) return GenErrorCode.server;
    return GenErrorCode.unknown;
  }
}
