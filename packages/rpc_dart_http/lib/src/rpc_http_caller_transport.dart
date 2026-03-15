// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

/// Pending outgoing HTTP call state.
final class _PendingCall {
  final String methodPath;
  final List<RpcHeader> requestHeaders;
  final BytesBuilder bodyBuffer = BytesBuilder();

  _PendingCall({required this.methodPath, required this.requestHeaders});
}

/// Maps an HTTP status code to a gRPC status int ([RpcStatus] constants).
int _httpStatusToGrpcCode(int statusCode) {
  switch (statusCode) {
    case HttpStatus.badRequest:
      return RpcStatus.invalidArgument;
    case HttpStatus.unauthorized:
      return RpcStatus.unauthenticated;
    case HttpStatus.forbidden:
      return RpcStatus.permissionDenied;
    case HttpStatus.notFound:
      return RpcStatus.unimplemented;
    case HttpStatus.conflict:
      return RpcStatus.aborted;
    case HttpStatus.gone:
      return RpcStatus.notFound;
    case HttpStatus.preconditionFailed:
      return RpcStatus.failedPrecondition;
    case HttpStatus.requestEntityTooLarge:
      return RpcStatus.resourceExhausted;
    case HttpStatus.tooManyRequests:
      return RpcStatus.resourceExhausted;
    case 499: // Client Closed Request (nginx convention)
      return RpcStatus.cancelled;
    case HttpStatus.internalServerError:
      return RpcStatus.internal;
    case HttpStatus.notImplemented:
      return RpcStatus.unimplemented;
    case HttpStatus.badGateway:
      return RpcStatus.unavailable;
    case HttpStatus.serviceUnavailable:
      return RpcStatus.unavailable;
    case HttpStatus.gatewayTimeout:
      return RpcStatus.deadlineExceeded;
    case HttpStatus.unsupportedMediaType:
      return RpcStatus.invalidArgument;
    default:
      if (statusCode >= 500) return RpcStatus.internal;
      if (statusCode >= 400) return RpcStatus.invalidArgument;
      return RpcStatus.unknown;
  }
}

/// HTTP/1.1 caller transport for rpc_dart.
///
/// Maps each RPC stream to one HTTP POST request.
/// Only unary calls are supported — streaming methods will fail because
/// HTTP/1.1 cannot multiplex messages in both directions within a single
/// request/response cycle.
///
/// Wire format:
///   Request:  POST {baseUrl}{methodPath}  body = gRPC-framed bytes
///   Response: 200 OK                      body = gRPC-framed bytes
///             All response headers (including grpc-status) are in HTTP headers.
class RpcHttpCallerTransport implements IRpcTransport {
  final String _baseUrl;
  final HttpClient _httpClient;
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: true);
  final Map<int, _PendingCall> _pending = {};
  // Stream IDs that are currently awaiting an HTTP response.
  final Set<int> _inFlight = {};
  final StreamController<RpcTransportMessage> _incoming =
      StreamController<RpcTransportMessage>.broadcast();
  bool _isClosed = false;
  final RpcLogger? _logger;

  RpcHttpCallerTransport({
    required String baseUrl,
    HttpClient? httpClient,
    RpcLogger? logger,
    /// TLS security context for HTTPS connections.
    SecurityContext? securityContext,
    /// Called when the server certificate cannot be verified.
    /// Return `true` to accept the certificate anyway (e.g. for self-signed
    /// certs in development). Defaults to strict verification.
    bool Function(X509Certificate, String, int)? badCertificateCallback,
    /// Timeout for establishing a TCP connection. If null, the platform
    /// default is used.
    Duration? connectionTimeout,
    /// How long an idle keep-alive connection may remain in the pool before
    /// it is closed. If null, the platform default is used.
    Duration? idleTimeout,
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _httpClient = httpClient ?? HttpClient(context: securityContext),
        _logger = logger?.child('HttpCallerTransport') {
    if (httpClient == null) {
      if (badCertificateCallback != null) {
        _httpClient.badCertificateCallback = badCertificateCallback;
      }
      if (connectionTimeout != null) {
        _httpClient.connectionTimeout = connectionTimeout;
      }
      if (idleTimeout != null) {
        _httpClient.idleTimeout = idleTimeout;
      }
    }
  }

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _isClosed;

  @override
  int createStream() {
    if (_isClosed) throw StateError('Transport is closed');
    return _idManager.generateId();
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
    if (_isClosed) throw StateError('Transport is closed');
    final methodPath = metadata.methodPath ?? '/Unknown/Unknown';
    _pending[streamId] = _PendingCall(
      methodPath: methodPath,
      requestHeaders: metadata.headers.toList(),
    );
    if (endStream) {
      await _fireRequest(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');
    final call = _pending[streamId];
    if (call == null) {
      throw StateError('No pending call for stream $streamId. Call sendMetadata first.');
    }
    call.bodyBuffer.add(data);
    if (endStream) {
      await _fireRequest(streamId);
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    await _fireRequest(streamId);
  }

  Future<void> _fireRequest(int streamId) async {
    final call = _pending.remove(streamId);
    if (call == null) return;

    _inFlight.add(streamId);
    _logger?.internal('Firing HTTP POST ${call.methodPath} [streamId: $streamId]');

    final uri = Uri.parse('$_baseUrl${call.methodPath}');
    try {
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType('application', 'grpc+proto');
      for (final header in call.requestHeaders) {
        // Skip HTTP/2 pseudo-headers and content-type (set explicitly above).
        if (header.name.startsWith(':') ||
            header.name == RpcConstants.contentTypeHeader) {
          continue;
        }
        request.headers.add(header.name, header.value);
      }

      final body = call.bodyBuffer.takeBytes();
      request.contentLength = body.length;
      request.add(body);

      final response = await request.close();

      _logger?.internal(
        'HTTP response ${response.statusCode} for [streamId: $streamId]',
      );

      // Non-200 responses without gRPC trailers are mapped to RpcErrors.
      if (response.statusCode != HttpStatus.ok) {
        // Drain the response body to free the connection.
        await response.drain<void>();
        // Synthesise a gRPC trailer so UnaryCaller resolves with a proper error.
        final grpcCode = _httpStatusToGrpcCode(response.statusCode);
        if (!_incoming.isClosed) {
          _incoming.add(RpcTransportMessage(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcConstants.grpcStatusHeader, '$grpcCode'),
              RpcHeader(
                RpcConstants.grpcMessageHeader,
                Uri.encodeComponent('HTTP ${response.statusCode} from ${call.methodPath}'),
              ),
            ]),
            isEndOfStream: true,
          ));
        }
        return;
      }

      // Split response headers into initial headers and gRPC trailer headers.
      // The server puts both in HTTP response headers (HTTP/1.1 has no trailers).
      // UnaryCaller expects a separate trailer message with isEndOfStream: true
      // that carries grpc-status / grpc-message.
      final initialHeaders = <RpcHeader>[];
      final trailerHeaders = <RpcHeader>[];
      response.headers.forEach((name, values) {
        for (final value in values) {
          final header = RpcHeader(name, value);
          if (name == RpcConstants.grpcStatusHeader ||
              name == RpcConstants.grpcMessageHeader) {
            trailerHeaders.add(header);
          } else {
            initialHeaders.add(header);
          }
        }
      });

      // Emit initial response metadata.
      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(initialHeaders),
          isEndOfStream: false,
          methodPath: call.methodPath,
        ));
      }

      // Read response body.
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final responseBytes = builder.takeBytes();

      if (responseBytes.isNotEmpty && !_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          payload: Uint8List.fromList(responseBytes),
          isEndOfStream: false,
          methodPath: call.methodPath,
        ));
      }

      // Emit gRPC trailer as a separate metadata-only message with endOfStream.
      // This mirrors how HTTP/2 sends trailing headers, letting UnaryCaller
      // detect grpc-status and complete (or error) the call.
      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(trailerHeaders),
          isEndOfStream: true,
        ));
      }
    } catch (e, st) {
      _logger?.error(
        'HTTP request failed for [streamId: $streamId]',
        error: e,
        stackTrace: st,
      );
      if (!_incoming.isClosed) {
        _incoming.addError(e, st);
      }
    } finally {
      _inFlight.remove(streamId);
      _idManager.releaseId(streamId);
    }
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
        message: 'HTTP caller transport closed',
      );
    }
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP caller transport ready',
      details: {'baseUrl': _baseUrl},
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    // HTTP/1.1 is stateless — no reconnect needed.
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP is stateless, no reconnect required',
      details: {'baseUrl': _baseUrl},
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _pending.clear();
    _httpClient.close(force: true);
    if (!_incoming.isClosed) {
      // Notify active subscribers (e.g. UnaryCaller) that the transport is
      // gone — but only if there are in-flight requests. Without this, those
      // callers' completers would never resolve, hanging their Futures.
      if (_inFlight.isNotEmpty) {
        _incoming.addError(StateError('Transport was closed'));
      }
      _inFlight.clear();
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
