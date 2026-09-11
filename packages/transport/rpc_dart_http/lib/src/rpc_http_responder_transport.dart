// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:shelf/shelf.dart';

import 'rpc_http_cors_policy.dart';

/// A request body over [RpcSecurityPolicy.maxMessageLengthBytes].
///
/// A distinct type rather than a `StateError`, because the answer differs: this
/// is 413 (RESOURCE_EXHAUSTED to the caller) while every other read failure is
/// 400 (INVALID_ARGUMENT). Matching on text would have been the fragile version
/// of the same thing -- rpc_dart_http2 tried that first and missed a wording.
final class _BodyTooLarge implements Exception {
  const _BodyTooLarge(this.limitBytes);

  final int limitBytes;

  @override
  String toString() => 'Request body exceeds limit of $limitBytes bytes';
}

/// Pending outgoing HTTP response state.
final class _PendingResponse {
  final Request shelfRequest;
  final Completer<Response> completer = Completer<Response>();
  final List<RpcHeader> responseHeaders = [];

  /// BytesBuilder, not `List<int>`: a Dart list holds WORD-SIZED elements, so
  /// this costs several times the response and `Uint8List.fromList` copies it
  /// again. It matters more here than on the request side, because this
  /// transport buffers a whole STREAMING response too — every item of every
  /// server stream lands here.
  ///
  /// Draining it with `takeBytes` is safe because `_flushResponse` removes the
  /// pending entry first, so no second flush can reach the same buffer.
  final BytesBuilder bodyBuffer = BytesBuilder(copy: false);

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
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream delivery for [getMessagesForStream]; the broadcast above is
  /// still fed for the responder pipeline's new-stream dispatch.
  final RpcStreamRouter _streams = RpcStreamRouter();
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
  /// through an `is IRpcSecurityPolicyAware` check. Declare only [IRpcTransport]
  /// and every one of those goes silently inert: a handler ceiling of 3 admits
  /// all 30 concurrent calls.
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
  /// dart:io never answers that header, so a client which sends it waits out its
  /// own fallback before transmitting the body (curl: one second). This budget
  /// is already running during that wait, so a short timeout expires before the
  /// first byte and the client gets a 408 saying it was too slow — when it was
  /// waiting for a `100 Continue` this server was never going to send. The
  /// missing `100 Continue` is the platform's, not this transport's: a bare
  /// shelf handler and a bare `HttpServer` behave identically.
  ///
  /// Who actually sends the header: curl for bodies over 1 KiB, and some proxies
  /// and load balancers. gRPC clients do not, so a pure gRPC deployment is
  /// unaffected — but this handler mounts on any shelf server.
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
  /// Rejections carry the CORS headers too, not just the success path in
  /// [_flushResponse]: a browser cannot read a cross-origin response without
  /// `Access-Control-Allow-Origin`, so a bare 415, 400, 408 or 503 reaches the
  /// page as an opaque CORS failure instead of the status the server chose.
  ///
  /// The request body is DRAINED before answering. Rejecting without reading it
  /// leaves unread bytes on the socket and dart:io tears the connection down
  /// before the status is flushed, so the peer gets a SocketException instead —
  /// the same hazard [_handleRequest]'s body reader documents.
  ///
  /// Drained under [bodyReadTimeout] rather than unbounded: `_reject` runs
  /// BEFORE the stream is registered, so these requests are counted by nothing,
  /// and an undeadlined drain makes a REFUSED request the cheaper attack than an
  /// accepted one. The subscription is CANCELLED on expiry — a `.timeout()` on
  /// the drain future returns the status while the read loop keeps running.
  Future<Response> _reject(
    int statusCode,
    Request request, {
    String? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    StreamSubscription<List<int>>? sub;
    try {
      sub = request.read().listen(null);
      final drained = sub.asFuture<void>();
      await (bodyReadTimeout == null
          ? drained
          : drained.timeout(bodyReadTimeout!));
    } catch (_) {
      // The peer may have gone already, or spent its budget; the status below
      // is still worth trying.
    } finally {
      await sub?.cancel();
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

    // gRPC is POST-only. Without this check every method runs the handler, and
    // GET is the one that matters: a browser can be made to issue a
    // cross-origin GET without a preflight, while a POST carrying
    // `content-type: application/grpc` cannot leave the origin unprompted -- so
    // accepting GET turns every unary method into something an attacker's page
    // can trigger.
    //
    // Only a FOREIGN caller picks the method (RpcHttpCallerTransport hard-codes
    // POST), so nothing in this library's own tests reaches it.
    //
    // Answered as HTTP 405 with `Allow` rather than as a gRPC status, matching
    // this transport's other pre-dispatch rejections (415, 400) --
    // gRPC-over-HTTP/2 must always send 200 plus grpc-status, but HTTP/1.1 need
    // not.
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
    // LOWERCASED first: RFC 9110 s8.3.1 makes the type and subtype
    // case-insensitive, so comparing the raw string refuses a legal
    // `Application/GRPC` with a 415.
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

    if (_logger?.isInternal ?? false) {
      _logger?.internal(
        'Incoming HTTP request $methodPath [streamId: $streamId]',
      );
    }

    try {
      // Collect and validate request headers.
      final requestHeaders = <RpcHeader>[];
      request.headers.forEach((name, value) {
        requestHeaders.add(RpcHeader(name, value));
      });

      if (policy != null) {
        // The AGGREGATE bound, which `validateMetadata` does not carry: it
        // checks maxHeaders and the per-header caps, and those do not imply a
        // total. The defaults allow 128 headers of 8 KiB, which is 1 MiB
        // against a 64 KiB `maxMetadataBytes` -- measured at 960 KB accepted
        // with 200 OK, every individual header legal.
        //
        // Counted here rather than in the policy because each transport knows
        // its own byte count: the frame channel bounds the serialized payload,
        // http2 the HPACK block, and this one the header lines. Same rule,
        // measured where the number is real.
        var metadataBytes = 0;
        for (final h in requestHeaders) {
          // `name: value\r\n` is the wire form; this undercounts by 4 per
          // header, so it can only ever reject later than the wire would.
          metadataBytes += h.name.length + h.value.length;
        }
        if (metadataBytes > policy.maxMetadataBytes) {
          _logger?.warning(
            'Rejected request: metadata block of $metadataBytes bytes exceeds '
            '${policy.maxMetadataBytes} [streamId: $streamId]',
          );
          _pending.remove(streamId);
          _idManager.releaseId(streamId);
          return _reject(
            400,
            request,
            body:
                'Metadata violation: metadata block of $metadataBytes bytes '
                'exceeds the limit of ${policy.maxMetadataBytes} bytes',
          );
        }

        try {
          policy.validateMetadata(RpcMetadata(requestHeaders));
        } on ArgumentError catch (e) {
          _logger?.warning(
            'Rejected request: metadata violation — $e [streamId: $streamId]',
          );
          _pending.remove(streamId);
          _idManager.releaseId(streamId);
          // The reason travels: the caller now repeats a bounded, single-line
          // prefix of this body in `grpc-message`, so a peer learns WHICH limit
          // it hit instead of only "HTTP 400 from /Svc/echo".
          return _reject(
            400,
            request,
            body: 'Metadata violation: ${e.message}',
          );
        }
      }

      // Read request body.
      //
      // On overflow, stop buffering but KEEP consuming to the end, discarding
      // the rest. Bailing out mid-body leaves unread bytes on the socket and
      // dart:io tears the connection down before the 400 is flushed, so the
      // client sees "Connection closed before full header was received" rather
      // than the status. Memory stays bounded because the buffer is dropped;
      // wall-clock is bounded by [bodyReadTimeout] when set.
      //
      // BytesBuilder, not `List<int>` + `Uint8List.fromList`: a Dart list holds
      // WORD-SIZED elements, so the buffer costs several times the body and the
      // final copy doubles it again -- for a body size the PEER chooses, bounded
      // only by maxMessageLengthBytes. At the 16 MiB default that was hundreds
      // of MiB of peak for ONE accepted request.
      Future<Uint8List> readBody() async {
        final builder = BytesBuilder(copy: false);
        var exceeded = false;
        await for (final chunk in request.read()) {
          if (exceeded) continue;
          builder.add(chunk);
          if (policy != null && builder.length > policy.maxMessageLengthBytes) {
            exceeded = true;
            builder.clear();
          }
        }
        if (exceeded) {
          throw _BodyTooLarge(policy!.maxMessageLengthBytes);
        }
        return builder.takeBytes();
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

      // Announced to the pipeline only once the whole request is in hand.
      // Emitting this BEFORE the body read opens pipeline state the transport
      // has no way to close when that read never completes, and RpcHttpServer
      // shares one responder endpoint across every connection, so those streams
      // are a budget all clients share.
      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata(requestHeaders),
          isEndOfStream: false,
          methodPath: methodPath,
        ),
      );
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
      // 413, not 400, for a body over the ceiling. The caller's
      // `_httpStatusToGrpcCode` maps 413 -> RESOURCE_EXHAUSTED and 400 ->
      // INVALID_ARGUMENT, so a 400 here tells a peer its ARGUMENTS were
      // malformed rather than its message too large -- and inverts the retry
      // semantics with it, since RpcRetryInterceptor treats RESOURCE_EXHAUSTED
      // as transient and INVALID_ARGUMENT as final.
      final statusCode = switch (e) {
        TimeoutException() => 408,
        _BodyTooLarge() => 413,
        _ => 400,
      };
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _reject(statusCode, request, body: e is _BodyTooLarge ? '$e' : null),
        );
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

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Flushing HTTP response [streamId: $streamId]');
    }

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

    final body = pending.bodyBuffer.takeBytes();
    pending.completer.complete(Response.ok(body, headers: headers));
    _idManager.releaseId(streamId);
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _streams[streamId];

  /// Routes a message to the broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
    _streams.add(message);
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

    _streams.closeAll();

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
