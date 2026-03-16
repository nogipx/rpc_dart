// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:shelf/shelf.dart';

/// gRPC headers that must always be exposed to the browser.
///
/// Without these in `Access-Control-Expose-Headers`, browsers block them
/// in cross-origin responses, breaking gRPC-over-HTTP on web clients.
const _requiredGrpcExposedHeaders = [
  'grpc-encoding',
  'grpc-accept-encoding',
  'grpc-status',
  'grpc-message',
];

/// gRPC headers that must always be allowed in browser requests.
const _requiredGrpcAllowedHeaders = [
  'grpc-timeout',
  'grpc-encoding',
  'grpc-accept-encoding',
];

/// CORS policy for [RpcHttpResponderTransport].
///
/// Controls which origins may call the RPC server from a browser and what
/// headers they may send. Also handles `OPTIONS` preflight requests.
///
/// The required gRPC headers (`grpc-encoding`, `grpc-status`, etc.) are always
/// included in `Access-Control-Expose-Headers` regardless of [extraExposedHeaders].
final class RpcHttpCorsPolicy {
  /// Origins allowed to access the server.
  ///
  /// Use `['*']` to allow any origin (incompatible with [allowCredentials]).
  final List<String> allowedOrigins;

  /// Additional request headers the browser may include on top of the
  /// required gRPC headers (reflected in `Access-Control-Allow-Headers`).
  final List<String> allowedHeaders;

  /// Additional response headers to expose to the browser on top of the
  /// required gRPC headers (reflected in `Access-Control-Expose-Headers`).
  final List<String> extraExposedHeaders;

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
      'x-trace-id',
      'x-request-id',
    ],
    this.extraExposedHeaders = const [],
    this.allowCredentials = false,
    this.preflightMaxAge,
  }) : assert(
          !(allowCredentials && allowedOrigins.contains('*')),
          'allowCredentials=true requires specific origins, not ["*"]',
        );

  List<String> get _allAllowedHeaders => [
        ..._requiredGrpcAllowedHeaders,
        ...allowedHeaders,
      ];

  List<String> get _allExposedHeaders => [
        ..._requiredGrpcExposedHeaders,
        ...extraExposedHeaders,
      ];

  /// Applies CORS response headers into [headers] map for a regular request.
  void applyTo(Map<String, String> headers, String? requestOrigin) {
    final origin = _resolveOrigin(requestOrigin);
    if (origin == null) return;
    headers['access-control-allow-origin'] = origin;
    if (allowCredentials) {
      headers['access-control-allow-credentials'] = 'true';
    }
    headers['access-control-expose-headers'] = _allExposedHeaders.join(', ');
  }

  /// Handles an `OPTIONS` preflight [request] and returns the shelf [Response].
  Response handlePreflight(Request request) {
    final requestOrigin = request.headers['origin'];
    final origin = _resolveOrigin(requestOrigin);

    if (origin == null) {
      return Response.forbidden('');
    }

    final headers = <String, String>{
      'access-control-allow-origin': origin,
      'access-control-allow-methods': 'POST, OPTIONS',
      'access-control-allow-headers': _allAllowedHeaders.join(', '),
      'access-control-expose-headers': _allExposedHeaders.join(', '),
    };
    if (allowCredentials) {
      headers['access-control-allow-credentials'] = 'true';
    }
    if (preflightMaxAge != null) {
      headers['access-control-max-age'] = preflightMaxAge!.inSeconds.toString();
    }
    return Response(204, headers: headers);
  }

  String? _resolveOrigin(String? requestOrigin) {
    if (allowedOrigins.contains('*')) return '*';
    if (requestOrigin != null && allowedOrigins.contains(requestOrigin)) {
      return requestOrigin;
    }
    return null;
  }
}
