// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// CORS policy for [RpcHttpResponderTransport].
///
/// Controls which origins may call the RPC server from a browser and what
/// headers they may send. Also handles `OPTIONS` preflight requests.
final class RpcHttpCorsPolicy {
  /// Origins allowed to access the server.
  ///
  /// Use `['*']` to allow any origin (incompatible with [allowCredentials]).
  final List<String> allowedOrigins;

  /// Request headers the browser may include (reflected in
  /// `Access-Control-Allow-Headers`).
  final List<String> allowedHeaders;

  /// Whether to include `Access-Control-Allow-Credentials: true`.
  ///
  /// Must be `false` when [allowedOrigins] contains `'*'`.
  final bool allowCredentials;

  /// Value for `Access-Control-Max-Age` (preflight cache duration).
  /// If null, the header is not sent.
  final Duration? preflightMaxAge;

  RpcHttpCorsPolicy({
    this.allowedOrigins = const ['*'],
    this.allowedHeaders = const [
      'content-type',
      'authorization',
      'x-requested-with',
      'grpc-timeout',
      'x-trace-id',
      'x-request-id',
    ],
    this.allowCredentials = false,
    this.preflightMaxAge,
  }) : assert(
          !(allowCredentials && allowedOrigins.contains('*')),
          'allowCredentials=true requires specific origins, not ["*"]',
        );

  /// Applies CORS response headers for a regular (non-preflight) request.
  void applyTo(HttpResponse response, String? requestOrigin) {
    final origin = _resolveOrigin(requestOrigin);
    if (origin == null) return;
    response.headers.set('access-control-allow-origin', origin);
    if (allowCredentials) {
      response.headers.set('access-control-allow-credentials', 'true');
    }
  }

  /// Applies CORS response headers for an `OPTIONS` preflight request and
  /// writes a 204 No Content response.
  Future<void> handlePreflight(HttpRequest request) async {
    final response = request.response;
    final requestOrigin = request.headers.value('origin');
    final origin = _resolveOrigin(requestOrigin);

    if (origin == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    response.statusCode = HttpStatus.noContent;
    response.headers.set('access-control-allow-origin', origin);
    response.headers.set('access-control-allow-methods', 'POST, OPTIONS');
    response.headers.set(
      'access-control-allow-headers',
      allowedHeaders.join(', '),
    );
    if (allowCredentials) {
      response.headers.set('access-control-allow-credentials', 'true');
    }
    if (preflightMaxAge != null) {
      response.headers.set(
        'access-control-max-age',
        preflightMaxAge!.inSeconds.toString(),
      );
    }
    await response.close();
  }

  String? _resolveOrigin(String? requestOrigin) {
    if (allowedOrigins.contains('*')) return '*';
    if (requestOrigin != null && allowedOrigins.contains(requestOrigin)) {
      return requestOrigin;
    }
    return null;
  }
}
