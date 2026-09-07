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
class RpcHttpResponderTransport
    implements IRpcTransport, IRpcSecurityPolicyAware {
  final BufferedBroadcastController<RpcTransportMessage> _incoming =
      BufferedBroadcastController<RpcTransportMessage>();

  /// Per-stream dedicated controllers for [getMessagesForStream]; the broadcast
  /// above is still fed for the responder pipeline's new-stream dispatch.
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};
  final Map<int, _PendingResponse> _pending = {};
  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: false);
  bool _isClosed = false;
  final LogScope? _logger;

  /// Optional security policy: limits concurrent requests, body size, and
  /// header sizes.
  ///
  /// Null means this transport applies none of its OWN checks, which is why it
  /// is kept nullable here; the pipeline still gets defaults through
  /// [securityPolicy].
  final RpcSecurityPolicy? _securityPolicy;

  /// The policy the responder PIPELINE reads, via [IRpcSecurityPolicyAware].
  ///
  /// This transport enforces `maxActiveStreams`, the method path, metadata and
  /// the body size itself — but `maxConcurrentHandlers`, `halfOpenStreamTimeout`
  /// and the pre-method buffer budget belong to the pipeline, which finds them
  /// through an `is IRpcSecurityPolicyAware` check. Declaring only
  /// [IRpcTransport] made every one of those silently inert: measured with
  /// `maxConcurrentHandlers: 3` and 30 concurrent calls into a parked handler,
  ///
  ///     transport is IRpcSecurityPolicyAware : false
  ///     handlers entered                     : 30 of 30
  ///
  /// against 3 once the capability is declared. Exactly the defect
  /// `RpcHttp2ResponderTransport` had, and the sibling asymmetry is inside this
  /// package: `RpcHttpCallerTransport` has reported its policy this way all
  /// along.
  ///
  /// Falls back to the default policy when none was given, which is what the
  /// pipeline already did for a transport without the capability — so a server
  /// that passes no policy sees no change.
  @override
  RpcSecurityPolicy get securityPolicy =>
      _securityPolicy ?? const RpcSecurityPolicy();

  /// Optional CORS policy. When set, handles `OPTIONS` preflight requests
  /// automatically and attaches CORS headers to all responses.
  final RpcHttpCorsPolicy? corsPolicy;

  /// Maximum time to wait for the full request body to arrive.
  /// If null, no timeout is applied.
  ///
  /// CAUTION — this rejects a client that sends `Expect: 100-continue`.
  ///
  /// dart:io never answers that header, so a client which sends it waits out
  /// its own fallback before transmitting the body (curl: one second). The
  /// budget here is already running during that wait, so a short timeout
  /// expires before the first byte and the client gets a 408 saying it was too
  /// slow — when in fact it was waiting for a `100 Continue` this server was
  /// never going to send. Measured with curl, same server, same 4 KiB body,
  /// the header the only variable:
  ///
  ///     bodyReadTimeout 500ms + Expect: 100-continue -> HTTP 408 in 0.54s
  ///     bodyReadTimeout 500ms, no Expect             -> HTTP 200 in 0.02s
  ///     no timeout       + Expect: 100-continue      -> HTTP 200 in 1.01s
  ///
  /// The missing `100 Continue` is the platform's, not this transport's:
  /// a bare shelf handler and a bare `HttpServer` both take the same ~1.02s
  /// (measured as controls), so nothing here can send it.
  ///
  /// Who actually sends the header: curl for bodies over 1 KiB, and some
  /// proxies and load balancers. gRPC clients do not, so a pure gRPC
  /// deployment is unaffected — but this handler mounts on any shelf server.
  ///
  /// If that combination matters to you, the choice is a policy one and is
  /// deliberately left open: either leave [bodyReadTimeout] null on endpoints
  /// such clients reach, or set it comfortably above the client's
  /// continue-fallback (curl's is 1s). Shortening it tightens slowloris
  /// mitigation and widens this rejection at the same time.
  final Duration? bodyReadTimeout;

  RpcHttpResponderTransport({
    LogScope? logger,
    RpcSecurityPolicy? securityPolicy,
    this.corsPolicy,
    this.bodyReadTimeout,
  }) : _securityPolicy = securityPolicy,
       _logger = logger?.child('HttpResponderTransport');

  /// shelf [Handler] to mount on a shelf server or router.
  Handler get handler => _handleRequest;

  /// Builds a rejection carrying the CORS headers the policy promises.
  ///
  /// Only [_flushResponse] used to apply the policy, i.e. the SUCCESS path, so
  /// every rejection went out bare. A browser cannot read a cross-origin
  /// response without `Access-Control-Allow-Origin`, so 415, 400, 408 and 503
  /// were all invisible to a web client: the page saw an opaque CORS failure
  /// instead of the status the server actually chose, which is the difference
  /// between "your content-type is wrong" and no diagnosis at all.
  /// The request body is DRAINED before answering.
  ///
  /// Rejecting without reading it leaves unread bytes on the socket, and
  /// dart:io then tears the connection down before the status is flushed --
  /// the same hazard [_handleRequest]'s body reader documents. Measured while
  /// adding the 405 below: `PUT` came back as a SocketException instead of the
  /// status, while GET and DELETE happened to survive, purely because of how
  /// much was still buffered.
  ///
  /// Drained rather than bounded-and-abandoned for the same reason the body
  /// reader keeps consuming after an overflow: memory is safe because nothing
  /// is retained, and wall-clock is bounded by [bodyReadTimeout] when set.
  Future<Response> _reject(
    int statusCode,
    Request request, {
    String? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    try {
      await request.read().drain<void>();
    } catch (_) {
      // The peer may have gone already; the status below is still worth trying.
    }
    final headers = <String, String>{...extraHeaders};
    corsPolicy?.applyTo(headers, request.headers['origin']);
    return Response(statusCode, body: body, headers: headers);
  }

  Future<Response> _handleRequest(Request request) async {
    if (_isClosed) {
      return _reject(503, request, body: 'Transport closed');
    }

    // Handle CORS preflight before any other processing.
    if (request.method == 'OPTIONS' && corsPolicy != null) {
      return corsPolicy!.handlePreflight(request);
    }

    // gRPC is POST-only, and nothing checked. Measured with a body on every
    // method, counting handler executions: 6 of 6 ran -- POST, GET, HEAD, PUT,
    // DELETE and PATCH -- all answering grpc-status=0.
    //
    // GET is the one that matters. A browser can be made to issue a
    // cross-origin GET without a preflight, while a POST carrying
    // `content-type: application/grpc` cannot leave the origin unprompted, so
    // accepting GET turned every unary method into something an attacker's
    // page could trigger.
    //
    // RpcHttpCallerTransport hard-codes POST, which is why no test reached
    // this: only a foreign caller picks the method. Same defect and same blind
    // spot as 555d6855 on the HTTP/2 server.
    //
    // Answered as HTTP 405 with `Allow`, rather than as a gRPC status: this
    // transport already answers its pre-dispatch rejections with real HTTP
    // statuses (415 for content-type, 400 for a bad path), whereas
    // gRPC-over-HTTP/2 must always send 200 plus grpc-status. Each is
    // consistent with its own protocol.
    if (request.method != 'POST') {
      _logger?.warning('Rejected request: method ${request.method}, not POST');
      return _reject(405, request, extraHeaders: const {'allow': 'POST'});
    }

    // Enforce concurrent stream limit.
    //
    // Reads the nullable FIELD, not the getter: null still means "this
    // transport applies none of its own checks", and routing these through the
    // default-backed getter would silently switch limits on for a server that
    // passed no policy. That is a separate decision from making the pipeline
    // able to see the policy, which is what the getter is for.
    final policy = _securityPolicy;
    if (policy != null && _pending.length >= policy.maxActiveStreams) {
      _logger?.warning(
        'Rejected request: too many active streams (${_pending.length})',
      );
      return _reject(503, request);
    }

    // Validate Content-Type: must be a gRPC content type (application/grpc*).
    //
    // Lowercased first, because RFC 9110 s8.3.1 makes the type and subtype
    // CASE-INSENSITIVE, and this compared the raw string. Measured against this
    // server:
    //
    //     application/grpc        -> 200
    //     application/grpc+proto  -> 200
    //     Application/GRPC        -> 415   <- legal, and refused
    //     APPLICATION/GRPC+PROTO  -> 415   <- legal, and refused
    //     text/plain              -> 415   (correct)
    //
    // The HTTP/2 caller already lowercases before its equivalent check, so the
    // two halves of this library disagreed about the same header.
    final contentTypeValue = request.headers[RpcHeaders.contentType] ?? '';
    if (!contentTypeValue.toLowerCase().startsWith(
      RpcHeaders.contentTypeGrpc,
    )) {
      _logger?.warning(
        'Rejected request: unsupported Content-Type '
        '"$contentTypeValue" — expected application/grpc[+subtype]',
      );
      return _reject(415, request);
    }

    // Validate method path length.
    final methodPath = request.requestedUri.path;
    if (policy != null && !policy.isValidMethodPath(methodPath)) {
      _logger?.warning('Rejected request: invalid method path "$methodPath"');
      return _reject(400, request);
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
          return _reject(400, request);
        }
      }

      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(requestHeaders),
          isEndOfStream: false,
          methodPath: methodPath,
        ),
      );

      // Read request body.
      //
      // On overflow we stop buffering but keep consuming the stream to its end,
      // discarding the rest. Bailing out mid-body instead leaves unread bytes
      // on the socket, and dart:io then tears the connection down before the
      // 400 is flushed — the client sees "Connection closed before full header
      // was received" rather than the status. Memory stays bounded because the
      // buffer is dropped and later chunks are discarded; wall-clock is bounded
      // by [bodyReadTimeout] when it is set.
      Future<Uint8List> readBody() async {
        final bytes = <int>[];
        var exceeded = false;
        await for (final chunk in request.read()) {
          if (exceeded) continue;
          bytes.addAll(chunk);
          if (policy != null && bytes.length > policy.maxMessageLengthBytes) {
            exceeded = true;
            bytes.clear();
          }
        }
        if (exceeded) {
          throw StateError(
            'Request body exceeds limit of '
            '${policy!.maxMessageLengthBytes} bytes',
          );
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

      _emit(
        RpcTransportMessage(
          streamId: streamId,
          payload: body.isNotEmpty ? body : null,
          isEndOfStream: true,
          methodPath: methodPath,
        ),
      );
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
        pending.completer.complete(_reject(statusCode, request));
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
      _logger?.warning(
        'sendMetadata: no pending response for [streamId: $streamId]',
      );
      return;
    }
    // Enforce metadata invariants (printable-ASCII header values, etc.) on the
    // outgoing response, consistent with every other transport.
    securityPolicy.validateMetadata(metadata);
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
      _logger?.warning(
        'sendMessage: no pending response for [streamId: $streamId]',
      );
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
    final headers = <String, Object>{'content-type': 'application/grpc+proto'};

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
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    final existing = _streamControllers[streamId];
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
    );
    _streamControllers[streamId] = ctl;
    return ctl.stream;
  }

  /// Routes a message to the broadcast and the stream's dedicated controller,
  /// closing the latter on end-of-stream.
  void _emit(RpcTransportMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    if (message.isEndOfStream) {
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }

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
        pending.completer.complete(_reject(503, pending.shelfRequest));
      }
    }
    _pending.clear();

    for (final ctl in _streamControllers.values) {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
    _streamControllers.clear();

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
    throw UnsupportedError(
      'HTTP/1.1 transport does not support direct object transfer',
    );
  }
}
