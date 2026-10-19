import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/gen_types.dart';

/// Shared helpers for the "bring your own key" (paid) providers.
/// Keys are passed in at call time and are never logged or put in URLs.
abstract class _KeyedClient implements ImageGenerator {
  final http.Client http_;
  final String apiKey;
  final Duration timeout;
  _KeyedClient(this.http_, this.apiKey, this.timeout);

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  void ensureKey() {
    if (!isConfigured) {
      throw GenException(
        GenErrorCode.notConfigured,
        'No API key saved',
        provider: id,
      );
    }
  }

  Future<http.Response> guard(Future<http.Response> f) async {
    try {
      return await f.timeout(timeout);
    } on TimeoutException {
      throw GenException(
        GenErrorCode.timeout,
        'No answer in ${timeout.inSeconds}s',
        provider: id,
      );
    } on SocketException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    } on http.ClientException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    }
  }

  GenException errorFrom(http.Response r) => mapPaidError(id, r);
}

GenException mapPaidError(ProviderId id, http.Response r) {
  final s = r.statusCode;
  String msg = 'HTTP $s';
  String type = '';
  try {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map) {
      final e = j['error'];
      if (e is Map) {
        msg = (e['message'] ?? msg).toString();
        type = '${e['code'] ?? ''} ${e['type'] ?? ''}';
      } else if (e is String) {
        msg = e;
      } else if (j['errors'] is List && (j['errors'] as List).isNotEmpty) {
        msg = (j['errors'] as List).join('; ');
        type = (j['name'] ?? '').toString();
      } else if (j['message'] != null) {
        msg = j['message'].toString();
      }
    }
  } catch (_) {
    final body = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (body.isNotEmpty && body.length < 300) msg = body;
  }
  final lower = '$msg $type'.toLowerCase();
  GenErrorCode code;
  if (lower.contains('insufficient_quota') ||
      lower.contains('billing') ||
      lower.contains('credits') ||
      lower.contains('spending limit') ||
      s == 402) {
    code = GenErrorCode.quota;
  } else if (lower.contains('moderation') ||
      lower.contains('safety') ||
      lower.contains('content_policy') ||
      lower.contains('content policy')) {
    code = GenErrorCode.contentFiltered;
  } else if (s == 401) {
    code = GenErrorCode.auth;
  } else if (s == 403) {
    code = id == ProviderId.stability
        ? GenErrorCode.contentFiltered
        : GenErrorCode.auth;
  } else if (s == 429) {
    code = GenErrorCode.rateLimited;
  } else if (s == 400 || s == 404 || s == 413 || s == 422) {
    code = GenErrorCode.badRequest;
  } else if (s >= 500) {
    code = GenErrorCode.server;
  } else {
    code = GenErrorCode.unknown;
  }
  return GenException(
    code,
    msg,
    provider: id,
    httpStatus: s,
    retryAfter: parseRetryAfter(r.headers['retry-after']),
  );
}

/// xAI Imagine API (OpenAI-compatible): POST https://api.x.ai/v1/images/generations
/// https://docs.x.ai/docs/guides/image-generation
class XaiClient extends _KeyedClient {
  static const endpoint = 'https://api.x.ai/v1/images/generations';
  static const defaultModel = 'grok-imagine-image-2.0';
  final String model;

  XaiClient(
    http.Client c,
    String key, {
    String? model,
    Duration timeout = const Duration(seconds: 120),
  }) : model = (model == null || model.trim().isEmpty)
           ? defaultModel
           : model.trim(),
       super(c, key, timeout);

  @override
  ProviderId get id => ProviderId.xai;

  Map<String, dynamic> buildBody(GenRequest req) => {
    'model': model,
    'prompt': req.prompt,
    'n': 1,
    'response_format': 'b64_json',
    'aspect_ratio': req.aspect.ratio,
  };

  @override
  Future<GenImage> generate(GenRequest req) async {
    ensureKey();
    final r = await guard(
      http_.post(
        Uri.parse(endpoint),
        headers: {
          'Authorization': 'Bearer ${apiKey.trim()}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(buildBody(req)),
      ),
    );
    if (r.statusCode != 200) throw errorFrom(r);
    final bytes = await decodeOpenAiStyle(r, http_, id, guard);
    return GenImage(
      bytes: bytes,
      mime: sniffMime(bytes),
      provider: id,
      model: model,
      seed: req.seed,
    );
  }
}

/// OpenAI Image API: POST https://api.openai.com/v1/images/generations
/// GPT Image models always return data[0].b64_json.
class OpenAiClient extends _KeyedClient {
  static const endpoint = 'https://api.openai.com/v1/images/generations';
  static const defaultModel = 'gpt-image-2.5-flare';
  final String model;

  OpenAiClient(
    http.Client c,
    String key, {
    String? model,
    Duration timeout = const Duration(seconds: 180),
  }) : model = (model == null || model.trim().isEmpty)
           ? defaultModel
           : model.trim(),
       super(c, key, timeout);

  @override
  ProviderId get id => ProviderId.openai;

  static String sizeFor(ImageAspect a) => switch (a) {
    ImageAspect.square => '1024x1024',
    ImageAspect.portrait => '1024x1536',
    ImageAspect.landscape => '1536x1024',
  };

  Map<String, dynamic> buildBody(GenRequest req) => {
    'model': model,
    'prompt': req.prompt,
    'n': 1,
    'size': sizeFor(req.aspect),
  };

  @override
  Future<GenImage> generate(GenRequest req) async {
    ensureKey();
    final r = await guard(
      http_.post(
        Uri.parse(endpoint),
        headers: {
          'Authorization': 'Bearer ${apiKey.trim()}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(buildBody(req)),
      ),
    );
    if (r.statusCode != 200) throw errorFrom(r);
    final bytes = await decodeOpenAiStyle(r, http_, id, guard);
    return GenImage(
      bytes: bytes,
      mime: sniffMime(bytes),
      provider: id,
      model: model,
      seed: req.seed,
    );
  }
}

/// Reads {data:[{b64_json|url}]} and returns image bytes.
Future<Uint8List> decodeOpenAiStyle(
  http.Response r,
  http.Client c,
  ProviderId id,
  Future<http.Response> Function(Future<http.Response>) guard,
) async {
  try {
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final first = (j['data'] as List).first as Map<String, dynamic>;
    final b64 = first['b64_json'] as String?;
    if (b64 != null && b64.isNotEmpty) return base64Decode(b64);
    final url = first['url'] as String?;
    if (url != null) {
      final img = await guard(c.get(Uri.parse(url)));
      if (img.statusCode == 200 && looksLikeImage(img.bodyBytes)) {
        return img.bodyBytes;
      }
    }
  } catch (_) {}
  throw GenException(
    GenErrorCode.server,
    'Response had no image',
    provider: id,
  );
}

/// Stability AI Stable Image Core:
/// POST https://api.stability.ai/v2beta/stable-image/generate/core (multipart).
class StabilityClient extends _KeyedClient {
  static const endpoint =
      'https://api.stability.ai/v2beta/stable-image/generate/core';

  StabilityClient(
    http.Client c,
    String key, {
    Duration timeout = const Duration(seconds: 120),
  }) : super(c, key, timeout);

  @override
  ProviderId get id => ProviderId.stability;

  Map<String, String> buildFields(GenRequest req) => {
    'prompt': req.prompt,
    'aspect_ratio': req.aspect.ratio,
    'seed': '${req.seed % 4294967294}',
    'output_format': 'jpeg',
  };

  @override
  Future<GenImage> generate(GenRequest req) async {
    ensureKey();
    final mr = http.MultipartRequest('POST', Uri.parse(endpoint))
      ..headers['Authorization'] = 'Bearer ${apiKey.trim()}'
      ..headers['Accept'] = 'image/*'
      ..headers['stability-client-id'] = 'imagine-pad'
      ..fields.addAll(buildFields(req));
    final r = await guard(sendForm(mr));
    if (r.statusCode != 200) throw errorFrom(r);
    if (!looksLikeImage(r.bodyBytes)) {
      throw GenException(
        GenErrorCode.server,
        'Response had no image',
        provider: id,
      );
    }
    return GenImage(
      bytes: r.bodyBytes,
      mime: sniffMime(r.bodyBytes),
      provider: id,
      model: 'stable-image-core',
      seed: int.tryParse(r.headers['seed'] ?? '') ?? req.seed,
    );
  }

  Future<http.Response> sendForm(http.MultipartRequest mr) async =>
      http.Response.fromStream(await http_.send(mr));
}
