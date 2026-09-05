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
/// Maps each RPC stream to one HTTP POST request. Use it for UNARY calls.
///
/// ## What streaming methods actually do here
///
/// This used to say streaming methods "will fail". They do not fail, and the
/// difference matters. Measured against a real server on this transport:
///
///  * A FINITE stream SUCCEEDS, fully buffered. A server stream of three items
///    yielded 400ms apart arrived as `[1290, 1290, 1290]`ms — nothing until the
///    handler completed, then everything at once. Client-streaming and
///    bidirectional round-trip too, for the same reason: the whole exchange
///    fits in one request/response pair. Nothing warns that the streaming
///    semantics are gone.
///  * An UNBOUNDED stream HANGS, and leaks. A server stream that never
///    completes produced no items in 5s while the handler kept running — 225
///    yields by the time the client gave up, and still going afterwards. There
///    is no response until the handler finishes, so a handler that never
///    finishes hangs the caller and burns server resources with nothing to
///    stop it.
///
/// So the practical rule is not "streaming fails" but "streaming silently
/// degrades to buffering, and an unbounded stream is a hang". Prefer
/// [`rpc_dart_http2`], [`rpc_dart_websocket`] or [`rpc_dart_isolate`] for any
/// streaming method; if one must run here, give it a deadline so the hang is
/// bounded.
///
/// Uses [package:http](https://pub.dev/packages/http) and compiles to all
/// platforms including JS/Wasm.
///
/// Wire format:
///   Request:  POST {baseUrl}{methodPath}  body = gRPC-framed bytes
///   Response: 200 OK                      body = gRPC-framed bytes
///             All response headers (including grpc-status) are in HTTP headers.
class RpcHttpCallerTransport implements IRpcTransport, IRpcSecurityPolicyAware {
  final String _baseUrl;
  final http.Client _httpClient;
  final RpcSecurityPolicy _policy;
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: true);
  final Map<int, _PendingCall> _pending = {};
  final Set<int> _inFlight = {};
  final BufferedBroadcastController<RpcTransportMessage> _incoming =
      BufferedBroadcastController<RpcTransportMessage>();

  /// Per-stream dedicated controllers for [getMessagesForStream], so each call
  /// is fed directly instead of every caller re-filtering the shared broadcast
  /// (O(active-streams) per message). Also keeps a stream-scoped error from
  /// leaking onto other concurrent calls' subscribers.
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};
  bool _isClosed = false;
  final LogScope? _logger;

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
  /// [policy] bounds what a RESPONSE may cost this client, and is reported to
  /// the endpoint layers through [IRpcSecurityPolicyAware]. It defaults to
  /// `const RpcSecurityPolicy()`, so the built-in limits apply out of the box.
  RpcHttpCallerTransport({
    required String baseUrl,
    http.Client? httpClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    LogScope? logger,
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _httpClient = httpClient ?? http.Client(),
       _policy = policy,
       _logger = logger?.child('HttpCallerTransport');

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  /// Reads the response body, refusing to buffer more than the policy allows.
  ///
  /// This used to be `http.Response.fromStream`, which buffers the whole body
  /// before anything inspects it. The responder side bounds the REQUEST body
  /// against the same ceiling; the caller had no bound in the other direction
  /// and took no policy at all, so whatever a server, a proxy or a captive
  /// portal sent was allocated in full.
  ///
  /// Measured with a server answering 192 MiB and the default policy, resident
  /// memory across one call grew by 756 MiB — the streamed copy, the
  /// concatenated body, and the parser's buffer — and only then did the frame
  /// parser reject it with "gRPC frame buffer overflow: 201326592 bytes".
  /// The limit existed; it just fired after the damage.
  ///
  /// Overflow aborts the read immediately: unlike the server, which must keep
  /// draining so its 400 reaches the client, nothing here needs the rest of a
  /// body already known to be too big.
  Future<Uint8List> _readBounded(
    http.StreamedResponse response,
    int streamId,
  ) async {
    final limit = _policy.maxMessageLengthBytes;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw RpcException(
          'HTTP response body exceeds the configured limit of $limit bytes '
          '(stream $streamId, method ${response.request?.url.path}). Raise '
          'RpcSecurityPolicy.maxMessageLengthBytes if this is expected.',
        );
      }
    }
    return builder.takeBytes();
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
    // Enforce the metadata invariants (printable-ASCII header values, etc.)
    // on send, consistent with every other transport. HTTP/1.1 puts these on
    // the wire as headers, so non-ASCII / CR-LF would corrupt or inject.
    _policy.validateMetadata(metadata);
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
      throw StateError(
        'No pending call for stream $streamId. Call sendMetadata first.',
      );
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
    _logger?.internal(
      'Firing HTTP POST ${call.methodPath} [streamId: $streamId]',
    );

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

      _logger?.internal(
        'HTTP response ${streamedResponse.statusCode} for [streamId: $streamId]',
      );

      if (streamedResponse.statusCode != 200) {
        // Drain before reporting: leaving bytes unread on the socket makes
        // dart:io tear the connection down, and package:http cannot reuse it.
        // Bounded by the same ceiling as a 200 body.
        await _readBounded(streamedResponse, streamId);
        final grpcCode = _httpStatusToGrpcCode(streamedResponse.statusCode);
        _emit(
          RpcTransportMessage(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcHeaders.grpcStatus, '$grpcCode'),
              RpcHeader(
                RpcHeaders.grpcMessage,
                Uri.encodeComponent(
                  'HTTP ${streamedResponse.statusCode} from ${call.methodPath}',
                ),
              ),
            ]),
            isEndOfStream: true,
          ),
        );
        return;
      }

      // Split response headers into initial headers and gRPC trailer headers.
      final initialHeaders = <RpcHeader>[];
      final trailerHeaders = <RpcHeader>[];
      streamedResponse.headers.forEach((name, value) {
        // package:http joins multi-values with ', ' — split them back.
        //
        // KNOWN LIMITATION, and it is not fixable at this layer. HTTP/1.1
        // permits a receiver to combine repeated field lines into one
        // comma-separated value (RFC 9110 s5.3), and package:http always does:
        // `BaseResponse.headers` is a `Map<String, String>`, so by the time the
        // response reaches here "two headers" and "one header containing a
        // comma-space" are already the same bytes. package:http's own
        // `headersSplitValues` is the identical naive comma split, so it offers
        // no more information.
        //
        // So both choices lose something, and this one splits. Measured against
        // a server sending each shape:
        //
        //   x-note: "hello, world"  (one value)   -> arrives as 2 headers
        //   x-list: "a, b"          (two values)  -> arrives as 2 headers  [ok]
        //
        // i.e. a single metadata value containing ", " is split, while genuine
        // repeated keys survive. NOT splitting would invert that: repeated gRPC
        // metadata keys — which the spec allows — would collapse into one
        // joined string.
        //
        // grpc-status and grpc-message are unaffected either way: the status is
        // numeric, and grpc-message is percent-encoded with an unreserved set of
        // ALPHA/DIGIT/-/./_/~, so both ',' and ' ' are escaped and the literal
        // ", " can never appear in it.
        //
        // Use rpc_dart_http2 (or websocket/isolate) if metadata values must
        // round-trip byte-for-byte; HTTP/2 keeps header fields separate.
        for (final v in value.split(', ')) {
          final header = RpcHeader(name, v);
          if (name == RpcHeaders.grpcStatus || name == RpcHeaders.grpcMessage) {
            trailerHeaders.add(header);
          } else {
            initialHeaders.add(header);
          }
        }
      });

      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(initialHeaders),
          isEndOfStream: false,
          methodPath: call.methodPath,
        ),
      );

      final responseBytes = await _readBounded(streamedResponse, streamId);
      if (responseBytes.isNotEmpty) {
        _emit(
          RpcTransportMessage(
            streamId: streamId,
            payload: responseBytes,
            isEndOfStream: false,
            methodPath: call.methodPath,
          ),
        );
      }

      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(trailerHeaders),
          isEndOfStream: true,
        ),
      );
    } catch (e, st) {
      _logger?.error(
        'HTTP request failed for [streamId: $streamId]',
        error: e,
        stackTrace: st,
      );
      _emitError(streamId, e, st);
    } finally {
      _inFlight.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    final existing = _streamControllers[streamId];
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
    );
    _streamControllers[streamId] = ctl;
    return ctl.stream;
  }

  /// Routes a message to the shared broadcast and the stream's dedicated
  /// controller, closing the latter on end-of-stream.
  void _emit(RpcTransportMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    if (message.isEndOfStream) {
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }

  /// Routes a stream-scoped error to the dedicated controller (so it does not
  /// leak onto other calls) while preserving the broadcast for global
  /// consumers.
  void _emitError(int streamId, Object error, StackTrace stackTrace) {
    final ctl = _streamControllers[streamId];
    if (ctl != null && !ctl.isClosed) ctl.addError(error, stackTrace);
    if (!_incoming.isClosed) _incoming.addError(error, stackTrace);
  }

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
      details: {
        'baseUrl': _baseUrl,
        // Per-call bookkeeping, exposed so growth is observable from outside:
        // all three must return to a baseline once calls finish.
        'pendingCalls': _pending.length,
        'inFlight': _inFlight.length,
        'streamControllers': _streamControllers.length,
      },
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
    for (final entry in _streamControllers.entries) {
      final ctl = entry.value;
      if (ctl.isClosed) continue;
      if (_inFlight.contains(entry.key)) {
        ctl.addError(StateError('Transport was closed'));
      }
      unawaited(ctl.close());
    }
    _streamControllers.clear();
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
    throw UnsupportedError(
      'HTTP/1.1 transport does not support direct object transfer',
    );
  }
}
