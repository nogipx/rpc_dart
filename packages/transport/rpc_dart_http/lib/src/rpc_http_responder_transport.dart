// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:shelf/shelf.dart';

import 'rpc_http_cors_policy.dart';

/// Pending outgoing HTTP response state.
final class _PendingResponse {
  final Request shelfRequest;
  final Completer<Response> completer = Completer<Response>();
  final List<RpcHeader> responseHeaders = [];
  final List<int> bodyBuffer = [];

  _PendingResponse(this.shelfRequest);
}

/// HTTP/1.1 responder transport for rpc_dart built on [package:shelf](https://pub.dev/packages/shelf).
///
/// Exposes a shelf [handler] that you mount on any shelf server or router.
/// Each incoming HTTP request becomes one RPC stream. The transport reads the
/// request body, emits metadata + data into [incomingMessages], then waits for
/// the responder endpoint to call [sendMetadata] / [sendMessage] /
/// [finishSending] before completing the shelf [Response].
///
/// Only unary RPC methods are supported.
///
/// Example with `shelf_io` (native platforms):
/// ```dart
/// import 'package:shelf/shelf_io.dart' as shelf_io;
///
/// final transport = RpcHttpResponderTransport();
/// final server = await shelf_io.serve(transport.handler, '127.0.0.1', 8080);
/// ```
class RpcHttpResponderTransport implements IRpcTransport {
  final StreamController<RpcTransportMessage> _incoming =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, _PendingResponse> _pending = {};
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: false);
  bool _isClosed = false;
  final LogScope? _logger;

  /// Optional security policy: limits concurrent requests, body size, and
  /// header sizes.
  final RpcSecurityPolicy? securityPolicy;

  /// Optional CORS policy. When set, handles `OPTIONS` preflight requests
  /// automatically and attaches CORS headers to all responses.
  final RpcHttpCorsPolicy? corsPolicy;

  /// Maximum time to wait for the full request body to arrive.
  /// If null, no timeout is applied.
  final Duration? bodyReadTimeout;

  RpcHttpResponderTransport({
    LogScope? logger,
    this.securityPolicy,
    this.corsPolicy,
    this.bodyReadTimeout,
  }) : _logger = logger?.child('HttpResponderTransport');

  /// shelf [Handler] to mount on a shelf server or router.
  Handler get handler => _handleRequest;

  Future<Response> _handleRequest(Request request) async {
    if (_isClosed) {
      return Response(503, body: 'Transport closed');
    }

    // Handle CORS preflight before any other processing.
    if (request.method == 'OPTIONS' && corsPolicy != null) {
      return corsPolicy!.handlePreflight(request);
    }

    // Enforce concurrent stream limit.
    final policy = securityPolicy;
    if (policy != null && _pending.length >= policy.maxActiveStreams) {
      _logger?.warning(
        'Rejected request: too many active streams (${_pending.length})',
      );
      return Response(503);
    }

    // Validate Content-Type: must be a gRPC content type (application/grpc*).
    final contentTypeValue = request.headers[RpcHeaders.contentType] ?? '';
    if (!contentTypeValue.startsWith('application/grpc')) {
      _logger?.warning(
        'Rejected request: unsupported Content-Type '
        '"$contentTypeValue" — expected application/grpc[+subtype]',
      );
      return Response(415);
    }

    // Validate method path length.
    final methodPath = request.requestedUri.path;
    if (policy != null && !policy.isValidMethodPath(methodPath)) {
      _logger?.warning('Rejected request: invalid method path "$methodPath"');
      return Response(400);
    }

    final streamId = _idManager.generateId();
    final pending = _PendingResponse(request);
    _pending[streamId] = pending;

    _logger?.internal(
      'Incoming HTTP request $methodPath [streamId: $streamId]',
    );

    try {
      // Collect and validate request headers.
      final requestHeaders = <RpcHeader>[];
      request.headers.forEach((name, value) {
        requestHeaders.add(RpcHeader(name, value));
      });

      if (policy != null) {
        try {
          policy.validateMetadata(RpcMetadata(requestHeaders));
        } on ArgumentError catch (e) {
          _logger?.warning(
            'Rejected request: metadata violation — $e [streamId: $streamId]',
          );
          _pending.remove(streamId);
          _idManager.releaseId(streamId);
          return Response(400);
        }
      }

      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(requestHeaders),
          isEndOfStream: false,
          methodPath: methodPath,
        ));
      }

      // Read request body.
      Future<Uint8List> readBody() async {
        final bytes = <int>[];
        await for (final chunk in request.read()) {
          bytes.addAll(chunk);
          if (policy != null && bytes.length > policy.maxMessageLengthBytes) {
            throw StateError(
              'Request body exceeds limit of ${policy.maxMessageLengthBytes} bytes',
            );
          }
        }
        return Uint8List.fromList(bytes);
      }

      final Uint8List body;
      if (bodyReadTimeout != null) {
        body = await readBody().timeout(
          bodyReadTimeout!,
          onTimeout: () => throw TimeoutException(
            'Body read timed out after $bodyReadTimeout',
            bodyReadTimeout,
          ),
        );
      } else {
        body = await readBody();
      }

      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          payload: body.isNotEmpty ? body : null,
          isEndOfStream: true,
          methodPath: methodPath,
        ));
      }
    } catch (e, st) {
      _pending.remove(streamId);
      _idManager.releaseId(streamId);
      _logger?.error(
        'Failed to read request [streamId: $streamId]: $e',
        error: e,
        stackTrace: st,
      );
      final statusCode = e is TimeoutException ? 408 : 400;
      if (!pending.completer.isCompleted) {
        pending.completer.complete(Response(statusCode));
      }
    }

    return pending.completer.future;
  }

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _isClosed;

  @override
  int createStream() {
    throw UnsupportedError(
      'HTTP/1.1 responder transport does not initiate outgoing streams. '
      'Stream IDs are assigned by incoming HTTP requests.',
    );
  }

  @override
  bool releaseStreamId(int streamId) {
    _pending.remove(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    final pending = _pending[streamId];
    if (pending == null) {
      _logger?.warning('sendMetadata: no pending response for [streamId: $streamId]');
      return;
    }
    // Enforce metadata invariants (printable-ASCII header values, etc.) on the
    // outgoing response, consistent with every other transport.
    (securityPolicy ?? const RpcSecurityPolicy()).validateMetadata(metadata);
    pending.responseHeaders.addAll(metadata.headers);
    if (endStream) {
      await _flushResponse(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    final pending = _pending[streamId];
    if (pending == null) {
      _logger?.warning('sendMessage: no pending response for [streamId: $streamId]');
      return;
    }
    pending.bodyBuffer.addAll(data);
    if (endStream) {
      await _flushResponse(streamId);
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    await _flushResponse(streamId);
  }

  Future<void> _flushResponse(int streamId) async {
    final pending = _pending.remove(streamId);
    if (pending == null) return;

    _logger?.internal('Flushing HTTP response [streamId: $streamId]');

    // Use Map<String, Object> to support multi-value headers (List<String>).
    final headers = <String, Object>{
      'content-type': 'application/grpc+proto',
    };

    if (corsPolicy != null) {
      final requestOrigin = pending.shelfRequest.headers['origin'];
      final corsHeaders = <String, String>{};
      corsPolicy!.applyTo(corsHeaders, requestOrigin);
      headers.addAll(corsHeaders);
    }

    for (final header in pending.responseHeaders) {
      if (header.name.startsWith(':')) continue;
      final existing = headers[header.name];
      if (existing == null) {
        headers[header.name] = header.value;
      } else if (existing is String) {
        headers[header.name] = [existing, header.value];
      } else {
        (existing as List<String>).add(header.value);
      }
    }

    final body = Uint8List.fromList(pending.bodyBuffer);
    pending.completer.complete(Response.ok(body, headers: headers));
    _idManager.releaseId(streamId);
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  Future<RpcHealthStatus> health() async {
    if (_isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP responder transport closed',
      );
    }
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP responder transport ready',
      details: {'pendingRequests': _pending.length},
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Server-side HTTP transport does not support reconnect',
      details: {'supported': false},
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    // Complete any pending responses with 503.
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(Response(503));
      }
    }
    _pending.clear();

    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  @override
  bool get supportsZeroCopy => false;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('HTTP/1.1 transport does not support direct object transfer');
  }
}
