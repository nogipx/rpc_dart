// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_http_cors_policy.dart';

/// Pending outgoing HTTP response state.
final class _PendingResponse {
  final HttpRequest httpRequest;
  final List<RpcHeader> responseHeaders = [];
  final BytesBuilder bodyBuffer = BytesBuilder();

  _PendingResponse(this.httpRequest);
}

/// HTTP/1.1 responder transport for rpc_dart.
///
/// Accepts a [Stream<HttpRequest>] — typically a filtered view of an
/// [HttpServer] — so multiple transports can share the same port.
///
/// Each incoming HTTP request becomes one RPC stream. The transport reads
/// the request body, emits metadata + data into [incomingMessages], then
/// waits for the responder endpoint to call [sendMetadata] / [sendMessage] /
/// [sendMetadata(endStream:true)] before flushing the HTTP response.
///
/// Only unary RPC methods are supported.
class RpcHttpResponderTransport implements IRpcTransport {
  final StreamController<RpcTransportMessage> _incoming =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, _PendingResponse> _pending = {};
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: false);
  StreamSubscription<HttpRequest>? _requestSubscription;
  bool _isClosed = false;
  final RpcLogger? _logger;

  /// Optional security policy: limits concurrent requests, body size, header
  /// sizes, and method-path length.
  final RpcSecurityPolicy? securityPolicy;

  /// Optional CORS policy. When set, handles `OPTIONS` preflight requests
  /// automatically and attaches CORS headers to all responses.
  final RpcHttpCorsPolicy? corsPolicy;

  /// Maximum time to wait for the full request body to arrive.
  /// If null, no timeout is applied.
  final Duration? bodyReadTimeout;

  RpcHttpResponderTransport(
    Stream<HttpRequest> requests, {
    RpcLogger? logger,
    this.securityPolicy,
    this.corsPolicy,
    this.bodyReadTimeout,
  }) : _logger = logger?.child('HttpResponderTransport') {
    _requestSubscription = requests.listen(
      _handleRequest,
      onError: (Object e, StackTrace st) {
        _logger?.error('HttpRequest stream error', error: e, stackTrace: st);
        if (!_incoming.isClosed) _incoming.addError(e, st);
      },
      onDone: () {
        _logger?.internal('HttpRequest stream done');
        close();
      },
    );
  }

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _isClosed;

  Future<void> _handleRequest(HttpRequest request) async {
    // Handle CORS preflight before any other processing.
    if (request.method == 'OPTIONS' && corsPolicy != null) {
      await corsPolicy!.handlePreflight(request);
      return;
    }

    // Enforce concurrent stream limit.
    final policy = securityPolicy;
    if (policy != null && _pending.length >= policy.maxActiveStreams) {
      _logger?.warning(
        'Rejected request: too many active streams (${_pending.length})',
      );
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    // Validate Content-Type: must be a gRPC content type (application/grpc*).
    final contentTypeValue = request.headers.value(RpcConstants.contentTypeHeader) ?? '';
    if (!contentTypeValue.startsWith('application/grpc')) {
      _logger?.warning(
        'Rejected request: unsupported Content-Type '
        '"$contentTypeValue" — expected application/grpc[+subtype]',
      );
      request.response.statusCode = HttpStatus.unsupportedMediaType;
      await request.response.close();
      return;
    }

    // Validate method path length.
    final methodPath = request.uri.path;
    if (policy != null && !policy.isValidMethodPath(methodPath)) {
      _logger?.warning('Rejected request: invalid method path "$methodPath"');
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final streamId = _idManager.generateId();
    _pending[streamId] = _PendingResponse(request);

    _logger?.internal(
      'Incoming HTTP request $methodPath [streamId: $streamId]',
    );

    try {
      // Validate and collect request headers.
      final requestHeaders = <RpcHeader>[];
      request.headers.forEach((name, values) {
        for (final value in values) {
          requestHeaders.add(RpcHeader(name, value));
        }
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
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
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

      // Read request body, optionally with a timeout.
      final builder = BytesBuilder();

      Future<void> readBody() async {
        await for (final chunk in request) {
          builder.add(chunk);
          if (policy != null &&
              builder.length > policy.maxMessageLengthBytes) {
            throw StateError(
              'Request body exceeds limit of ${policy.maxMessageLengthBytes} bytes',
            );
          }
        }
      }

      if (bodyReadTimeout != null) {
        await readBody().timeout(
          bodyReadTimeout!,
          onTimeout: () => throw TimeoutException(
            'Body read timed out after $bodyReadTimeout',
            bodyReadTimeout,
          ),
        );
      } else {
        await readBody();
      }

      final body = builder.takeBytes();

      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          payload: body.isNotEmpty ? Uint8List.fromList(body) : null,
          isEndOfStream: true,
          methodPath: methodPath,
        ));
      }
    } catch (e, st) {
      // Client disconnected, request timed out, body too large, etc.
      _pending.remove(streamId);
      _idManager.releaseId(streamId);
      _logger?.error(
        'Failed to read request [streamId: $streamId]: $e',
        error: e,
        stackTrace: st,
      );
      try {
        final statusCode = e is TimeoutException
            ? HttpStatus.requestTimeout
            : HttpStatus.badRequest;
        request.response.statusCode = statusCode;
        await request.response.close();
      } catch (_) {}
    }
  }

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
    pending.bodyBuffer.add(data);
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

    final response = pending.httpRequest.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType('application', 'grpc+proto');

    // Apply CORS headers to the response.
    if (corsPolicy != null) {
      final requestOrigin = pending.httpRequest.headers.value('origin');
      corsPolicy!.applyTo(response, requestOrigin);
    }

    for (final header in pending.responseHeaders) {
      if (!header.name.startsWith(':')) {
        response.headers.add(header.name, header.value);
      }
    }

    final body = pending.bodyBuffer.takeBytes();
    if (body.isNotEmpty) {
      response.add(body);
    }

    try {
      await response.close();
    } catch (e) {
      _logger?.warning('Error closing HTTP response [streamId: $streamId]: $e');
    }

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

    await _requestSubscription?.cancel();
    _requestSubscription = null;

    // Close any pending responses with 503.
    for (final pending in _pending.values) {
      try {
        pending.httpRequest.response.statusCode = HttpStatus.serviceUnavailable;
        await pending.httpRequest.response.close();
      } catch (_) {}
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
