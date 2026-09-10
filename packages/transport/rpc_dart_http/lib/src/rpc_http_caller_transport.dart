// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';

/// Pending outgoing HTTP call state.
final class _PendingCall {
  final String methodPath;
  final List<RpcHeader> requestHeaders;
  final List<int> bodyBuffer = [];

  _PendingCall({required this.methodPath, required this.requestHeaders});
}

/// Largest error body prefix carried into `grpc-message`.
///
/// The body of a non-200 is not necessarily ours: a proxy, a captive portal or
/// a load balancer answers with HTML, and the whole page has no place in a
/// status message. `_readBounded` already caps what is READ; this caps what is
/// repeated.
const int _maxReasonChars = 200;

/// Bytes read from a non-200 body before the read stops.
///
/// Generous against [_maxReasonChars] on purpose: the prefix may be multi-byte
/// UTF-8, and an HTML page usually puts its interesting words after some markup.
const int _maxReasonBytes = 8 * 1024;

/// A single-line, bounded, printable rendering of an error [body], or null when
/// there is nothing worth repeating.
///
/// Sanitised rather than trusted: `grpc-message` is percent-encoded on the wire
/// but ends up in logs and exception text, so control characters and line
/// breaks are collapsed rather than forwarded.
String? _shortReason(Uint8List body) {
  if (body.isEmpty) return null;
  final String text;
  try {
    text = utf8.decode(body, allowMalformed: true);
  } on FormatException {
    return null;
  }
  final collapsed = text
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s{2,}'), ' ');
  if (collapsed.isEmpty) return null;
  return collapsed.length > _maxReasonChars
      ? '${collapsed.substring(0, _maxReasonChars - 3)}...'
      : collapsed;
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
/// They do not fail — they silently degrade, which is worse:
///
///  * A FINITE stream SUCCEEDS, fully buffered. Nothing arrives until the
///    handler completes, then everything at once. Client-streaming and
///    bidirectional round-trip too, since the whole exchange fits in one
///    request/response pair. Nothing warns that the streaming semantics are
///    gone.
///  * An UNBOUNDED stream HANGS, and leaks. There is no response until the
///    handler finishes, so a handler that never finishes hangs the caller while
///    the server keeps producing, with nothing to stop it.
///
/// Prefer [`rpc_dart_http2`], [`rpc_dart_websocket`] or [`rpc_dart_isolate`] for
/// any streaming method; if one must run here, give it a deadline so the hang is
/// bounded.
///
/// Uses [package:http](https://pub.dev/packages/http) and compiles to all
/// platforms including JS/Wasm.
///
/// Wire format:
///   Request:  POST {baseUrl}{methodPath}  body = gRPC-framed bytes
///   Response: 200 OK                      body = gRPC-framed bytes
///             All response headers (including grpc-status) are in HTTP headers.
class RpcHttpCallerTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcStreamIdSequence {
  final String _baseUrl;
  final http.Client _httpClient;
  final RpcSecurityPolicy _policy;
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: true);
  final Map<int, _PendingCall> _pending = {};
  final Set<int> _inFlight = {};
  final BufferedBroadcastController<RpcTransportMessage> _incoming =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream delivery for [getMessagesForStream], so each call is fed
  /// directly instead of re-filtering the shared broadcast, and a stream-scoped
  /// error cannot leak onto other concurrent calls' subscribers.
  final RpcStreamRouter _streams = RpcStreamRouter();
  bool _isClosed = false;
  final LogScope? _logger;

  /// Creates an HTTP caller transport.
  ///
  /// Pass a custom [httpClient] to configure TLS, proxies, or other
  /// platform-specific settings. For example, to trust a private CA on native
  /// platforms, wrap a `dart:io` `HttpClient` via `package:http`'s `IOClient`:
  ///
  /// ```dart
  /// import 'dart:io';
  /// import 'package:http/io_client.dart';
  ///
  /// final context = SecurityContext(withTrustedRoots: true)
  ///   ..setTrustedCertificates('/etc/ssl/private-ca.pem');
  /// final transport = RpcHttpCallerTransport(
  ///   baseUrl: 'https://...',
  ///   httpClient: IOClient(HttpClient(context: context)),
  /// );
  /// ```
  ///
  /// Do NOT reach for `badCertificateCallback = (_, __, ___) => true`. It
  /// accepts every certificate, including an attacker's — a man-in-the-middle
  /// hole rather than a TLS configuration. Against a self-signed or private-CA
  /// server the snippet above is what actually works.
  ///
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

  /// Reads at most [_maxReasonBytes] of a NON-200 body and stops.
  ///
  /// NEVER throws, and that is the point. Routed through [_readBounded] instead,
  /// a peer's status dies of the size of the page that carried it — and losing
  /// UNAVAILABLE costs more than the text, because `RpcRetryInterceptor` retries
  /// it and does not retry a bare `RpcException`. A captive portal or a
  /// load-balancer HTML page is exactly this case.
  ///
  /// The status code is known BEFORE the body is read, so nothing here needs to
  /// fail. Consumption stops at the cap rather than draining the rest: a body
  /// already known to be too big has nothing left worth reading.
  Future<Uint8List> _readErrorBody(http.StreamedResponse response) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length >= _maxReasonBytes) break;
      }
    } catch (_) {
      // A body we could not finish reading is not worth failing the call over;
      // the status is already in hand.
    }
    return builder.takeBytes();
  }

  /// Reads the response body, refusing to buffer more than the policy allows.
  ///
  /// The responder bounds the REQUEST body against the same ceiling; this is the
  /// other direction, and without it whatever a server, a proxy or a captive
  /// portal sends is allocated in full. The frame parser has a limit of its own,
  /// but it fires only after the damage — by then the streamed copy, the
  /// concatenated body and the parser's buffer have all been paid for.
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

  /// See [IRpcStreamIdSequence].
  ///
  /// This transport has no `reconnect()` of its own, so the only thing that can
  /// swap it is `RpcClientConnection`, which builds a NEW one per attempt — and
  /// a new one restarts its ids at 1, handing the first call after the swap the
  /// id a call from the previous transport still holds.
  ///
  /// The collision bites HARDER here than on the streaming transports, because
  /// HTTP/1.1 buffers the whole request and `finishSending` is what SENDS it:
  /// `_pending[id]` holds the body, `finishSending(id)` fires the POST, and
  /// `releaseStreamId(id)` discards it. So a dead call's teardown either POSTs a
  /// live call's request early — with whatever body had been buffered so far —
  /// or throws it away so that call can never send at all.
  @override
  int get lastIssuedStreamId => _idManager.lastIssuedId;

  @override
  void resumeStreamIdsAfter(int streamId) => _idManager.resumeAfter(streamId);

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
        final errorBody = await _readErrorBody(streamedResponse);
        final grpcCode = _httpStatusToGrpcCode(streamedResponse.statusCode);
        // The reason travels. Discard the body and the responder's own
        // rejections -- "Request body exceeds limit of N bytes", a metadata
        // violation -- collapse into "HTTP 400 from /Svc/echo", which does not
        // say WHICH limit, or even that a limit was involved.
        final reason = _shortReason(errorBody);
        _emit(
          RpcTransportMessage(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcHeaders.grpcStatus, '$grpcCode'),
              RpcHeader(
                RpcHeaders.grpcMessage,
                Uri.encodeComponent(
                  'HTTP ${streamedResponse.statusCode} from ${call.methodPath}'
                  '${reason == null ? '' : ': $reason'}',
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
        // KNOWN LIMITATION, not fixable at this layer. HTTP/1.1 lets a receiver
        // combine repeated field lines into one comma-separated value (RFC 9110
        // s5.3) and package:http always does -- `BaseResponse.headers` is a
        // `Map<String, String>` -- so by the time a response reaches here, "two
        // headers" and "one header containing a comma-space" are the same bytes.
        //
        // Both choices therefore lose something, and this one SPLITS: a single
        // metadata value containing ", " is split apart, while genuinely
        // repeated keys survive. Not splitting inverts it, collapsing repeated
        // gRPC metadata keys -- which the spec allows -- into one joined string.
        //
        // grpc-status and grpc-message are unaffected either way: the status is
        // numeric, and grpc-message is percent-encoded over ALPHA/DIGIT/-/./_/~,
        // so the literal ", " can never appear in it.
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
      _emitError(streamId, _asRpcStatus(e, call.methodPath), st);
    } finally {
      _inFlight.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  /// Turns a transport-level failure into a gRPC status.
  ///
  /// A connection that is refused, reset, or closed mid-request surfaces from
  /// package:http as a raw [http.ClientException]. Passed through unchanged,
  /// nothing above the transport can act on it: retry, circuit breakers and
  /// failover all key off the gRPC status, so the most ordinary failure there
  /// is — the server went away — becomes unclassifiable, where the sibling
  /// transports all report UNAVAILABLE for it.
  ///
  /// UNAVAILABLE, not INTERNAL: the request did not reach a handler, or its
  /// answer never came back, so a fresh connection may well succeed — which is
  /// exactly what makes it retryable. Anything already carrying a status
  /// (including the non-200 mapping above and the frame parser's own errors) is
  /// passed through untouched.
  Object _asRpcStatus(Object error, String methodPath) {
    if (error is RpcStatusException || error is RpcException) return error;
    if (error is http.ClientException) {
      return RpcStatusException(
        RpcStatus.unavailable,
        'HTTP request to $methodPath failed: ${error.message}',
      );
    }
    return error;
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _streams[streamId];

  /// Routes a message to the shared broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
    _streams.add(message);
  }

  /// Routes a stream-scoped error to its own stream (so it does not leak onto
  /// other calls) while preserving the broadcast for global consumers.
  void _emitError(int streamId, Object error, StackTrace stackTrace) {
    _streams.addError(streamId, error, stackTrace);
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
        'streamControllers': _streams.length,
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
    // Only the calls actually in flight are told why they ended; the rest just
    // close. See [_closedDuringCall].
    _streams.closeAll(
      error: (id) => _inFlight.contains(id) ? _closedDuringCall() : null,
    );
    if (!_incoming.isClosed) {
      if (_inFlight.isNotEmpty) {
        _incoming.addError(_closedDuringCall());
      }
      _inFlight.clear();
      await _incoming.close();
    }
  }

  /// What a call still in flight is told when the transport is closed under it.
  ///
  /// A status rather than a bare `StateError`, because nothing above the
  /// transport can classify a `StateError` — and the code awaiting a call is
  /// very often NOT the code that called close(), so it gets something it can
  /// only string-match.
  ///
  /// UNAVAILABLE is chosen to MATCH the other three transports rather than on
  /// its own merits; `CANCELLED` (gRPC's code for a locally-aborted call, and
  /// non-retryable) is arguably the better fit and remains the maintainer's
  /// call, as a one-line change per transport. Matching is the smaller move: it
  /// removes the unclassifiable error without inventing a fourth behaviour.
  ///
  /// Deliberately NOT applied to a call made AFTER close: `createStream` keeps
  /// throwing `StateError('Transport is closed')`, matching every sibling. That
  /// is a programming error rather than a lifecycle event, and retrying it is
  /// futile.
  RpcStatusException _closedDuringCall() => RpcStatusException(
    RpcStatus.unavailable,
    'The transport was closed while this call was in flight',
  );

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
