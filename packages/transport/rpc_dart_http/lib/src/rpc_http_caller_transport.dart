// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';

/// Pending outgoing HTTP call state.
final class _PendingCall {
  final String methodPath;
  final List<RpcHeader> requestHeaders;
  final List<int> bodyBuffer = [];

  _PendingCall({required this.methodPath, required this.requestHeaders});
}

/// Maps an HTTP status code to a gRPC status int ([RpcStatus] constants).
int _httpStatusToGrpcCode(int statusCode) {
  switch (statusCode) {
    case 400:
      return RpcStatus.invalidArgument;
    case 401:
      return RpcStatus.unauthenticated;
    case 403:
      return RpcStatus.permissionDenied;
    case 404:
      return RpcStatus.unimplemented;
    case 409:
      return RpcStatus.aborted;
    case 410:
      return RpcStatus.notFound;
    case 412:
      return RpcStatus.failedPrecondition;
    case 413:
      return RpcStatus.resourceExhausted;
    case 429:
      return RpcStatus.resourceExhausted;
    case 499: // Client Closed Request (nginx convention)
      return RpcStatus.cancelled;
    case 500:
      return RpcStatus.internal;
    case 501:
      return RpcStatus.unimplemented;
    case 502:
      return RpcStatus.unavailable;
    case 503:
      return RpcStatus.unavailable;
    case 504:
      return RpcStatus.deadlineExceeded;
    case 415:
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
/// Uses [package:http](https://pub.dev/packages/http) and compiles to all
/// platforms including JS/Wasm.
///
/// Wire format:
///   Request:  POST {baseUrl}{methodPath}  body = gRPC-framed bytes
///   Response: 200 OK                      body = gRPC-framed bytes
///             All response headers (including grpc-status) are in HTTP headers.
class RpcHttpCallerTransport implements IRpcTransport {
  final String _baseUrl;
  final http.Client _httpClient;
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: true);
  final Map<int, _PendingCall> _pending = {};
  final Set<int> _inFlight = {};
  final StreamController<RpcTransportMessage> _incoming =
      StreamController<RpcTransportMessage>.broadcast();
  bool _isClosed = false;
  final RpcLogger? _logger;

  /// Creates an HTTP caller transport.
  ///
  /// Pass a custom [httpClient] to configure TLS, proxies, or other
  /// platform-specific settings. For example, on native platforms you can
  /// wrap a `dart:io` `HttpClient` via `package:http`'s `IOClient`:
  ///
  /// ```dart
  /// import 'dart:io';
  /// import 'package:http/io_client.dart';
  ///
  /// final ioClient = HttpClient()
  ///   ..badCertificateCallback = (cert, host, port) => true; // dev only
  /// final transport = RpcHttpCallerTransport(
  ///   baseUrl: 'https://...',
  ///   httpClient: IOClient(ioClient),
  /// );
  /// ```
  RpcHttpCallerTransport({
    required String baseUrl,
    http.Client? httpClient,
    RpcLogger? logger,
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _httpClient = httpClient ?? http.Client(),
        _logger = logger?.child('HttpCallerTransport');

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
    call.bodyBuffer.addAll(data);
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
      final request = http.Request('POST', uri);
      request.headers[RpcHeaders.contentType] = 'application/grpc+proto';
      // Required by gRPC-over-HTTP/1.1 to signal trailer support.
      request.headers['te'] = 'trailers';

      for (final header in call.requestHeaders) {
        if (header.name.startsWith(':') ||
            header.name == RpcHeaders.contentType) {
          continue;
        }
        request.headers[header.name] = header.value;
      }

      request.bodyBytes = Uint8List.fromList(call.bodyBuffer);

      final streamedResponse = await _httpClient.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      _logger?.internal(
        'HTTP response ${response.statusCode} for [streamId: $streamId]',
      );

      if (response.statusCode != 200) {
        final grpcCode = _httpStatusToGrpcCode(response.statusCode);
        if (!_incoming.isClosed) {
          _incoming.add(RpcTransportMessage(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcHeaders.grpcStatus, '$grpcCode'),
              RpcHeader(
                RpcHeaders.grpcMessage,
                Uri.encodeComponent('HTTP ${response.statusCode} from ${call.methodPath}'),
              ),
            ]),
            isEndOfStream: true,
          ));
        }
        return;
      }

      // Split response headers into initial headers and gRPC trailer headers.
      final initialHeaders = <RpcHeader>[];
      final trailerHeaders = <RpcHeader>[];
      response.headers.forEach((name, value) {
        // package:http joins multi-values with ', ' — split them back.
        for (final v in value.split(', ')) {
          final header = RpcHeader(name, v);
          if (name == RpcHeaders.grpcStatus || name == RpcHeaders.grpcMessage) {
            trailerHeaders.add(header);
          } else {
            initialHeaders.add(header);
          }
        }
      });

      if (!_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(initialHeaders),
          isEndOfStream: false,
          methodPath: call.methodPath,
        ));
      }

      final responseBytes = response.bodyBytes;
      if (responseBytes.isNotEmpty && !_incoming.isClosed) {
        _incoming.add(RpcTransportMessage(
          streamId: streamId,
          payload: responseBytes,
          isEndOfStream: false,
          methodPath: call.methodPath,
        ));
      }

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
    _httpClient.close();
    if (!_incoming.isClosed) {
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
