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

  /// Set once the response has been answered early — over the buffer ceiling.
  ///
  /// The entry STAYS in `_pending` afterwards so the handler's remaining sends
  /// land on it and are dropped silently. Removing it instead made every later
  /// frame log "no pending response", which for a stream that runs until
  /// cancelled is a line per message.
  bool answered = false;

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

  /// The security policy this transport's OWN checks read: concurrent requests,
  /// the method path, metadata size, and the request body.
  ///
  /// Nullable, and `null` really does switch all of them off — which is why the
  /// constructor defaults it to `const RpcSecurityPolicy()` rather than leaving
  /// it absent. Only this field is nullable; [securityPolicy], which the
  /// PIPELINE reads, falls back to the same default, so a null here made one
  /// object answer "what policy applies" two different ways — and the response
  /// side of this very class reads the non-null getter, so the response was
  /// bounded while the request body was not.
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

  /// Longest silence allowed while the request body arrives, reset by every
  /// chunk. Defaults to 30 seconds; null disables it.
  ///
  /// This is the bound that tells a stalled client from a slow one: a body that
  /// keeps arriving is never refused by it, whatever its size, and a client that
  /// stops is refused this long after its last byte. [bodyReadTimeout] bounds
  /// the total instead, which is size times throughput.
  final Duration? bodyIdleTimeout;

  /// Maximum time to wait for the full request body to arrive.
  /// If null, no timeout is applied.
  ///
  /// A TOTAL: an honest large upload over a slow link is refused at the same
  /// deadline as a stalled client. [bodyIdleTimeout] is the bound for stalls;
  /// this is an optional ceiling on top of it.
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

  /// Creates the transport.
  ///
  /// [securityPolicy] bounds the request body, the metadata block, the method
  /// path and concurrent requests. It defaults to a non-null
  /// [RpcSecurityPolicy] so the built-in limits are enforced out of the box;
  /// pass an explicit policy to tune them. Set it to `null` only to disable all
  /// of this transport's own limits (not recommended — this allows unbounded
  /// request bodies). [RpcHttpServer] takes the same parameter the same way.
  RpcHttpResponderTransport({
    LogScope? logger,
    RpcSecurityPolicy? securityPolicy = const RpcSecurityPolicy(),
    this.corsPolicy,
    this.bodyReadTimeout,
    this.bodyIdleTimeout = const Duration(seconds: 30),
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
  /// Drained under [bodyIdleTimeout] and [bodyReadTimeout] rather than
  /// unbounded: `_reject` runs
  /// BEFORE the stream is registered, so these requests are counted by nothing,
  /// and an undeadlined drain makes a REFUSED request the cheaper attack than an
  /// accepted one. The subscription is CANCELLED on expiry — a `.timeout()` on
  /// the drain future returns the status while the read loop keeps running.
  /// [drainBody] must be false once the body has ALREADY been read.
  ///
  /// `Request.read()` may be called once per request — shelf throws
  /// `StateError: The 'read' method can only be called once` on a second call —
  /// so the drain below is not merely redundant after `readBody()`, it raises. The
  /// 408, 413 and 400 paths all reject a request whose body reader has run, and
  /// the drain there did nothing but throw into a silent catch.
  ///
  /// Not needed there either: the body is still attached when the response
  /// completes, and dart:io detaches it then. Measured — a slow body past
  /// `bodyReadTimeout` receives its 408 and the peer can push only what the socket
  /// buffers afterwards, where the same client against an undeadlined read is
  /// answered nothing and pushes everything.
  Future<Response> _reject(
    int statusCode,
    Request request, {
    String? body,
    Map<String, String> extraHeaders = const {},
    bool drainBody = true,
  }) async {
    StreamSubscription<List<int>>? sub;
    final idle = _IdleDeadline(bodyIdleTimeout);
    if (drainBody) {
      try {
        sub = request.read().listen((_) => idle.arm());
        idle.arm();
        final drained = Future.any([sub.asFuture<void>(), idle.expired]);
        await (bodyReadTimeout == null
            ? drained
            : drained.timeout(bodyReadTimeout!));
      } on StateError catch (e) {
        // NOT silent. Every other failure here is the peer's doing; this one is
        // ours -- it can only mean the body was already read, so the caller wanted
        // `drainBody: false`.
        _logger?.warning('Rejection drain skipped: ${e.message}');
      } catch (_) {
        // The peer may have gone already, or spent its budget; the status below
        // is still worth trying.
      } finally {
        idle.cancel();
        await sub?.cancel();
      }
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

    // Validate Content-Type through the shared rule, which is the one home for
    // it: this check and core's pipeline used to be two copies that disagreed on
    // the ABSENT case, so the same request got 415 here and ran to the handler
    // over HTTP/2.
    //
    // STRICT here, not `policy.contentTypeValidation`, and the reason is the one
    // the POST check above rests on: `application/grpc` cannot leave an origin
    // unprompted, but NO content-type can — a cross-origin fetch with a typeless
    // body sends none and needs no preflight. Accepting that would put every
    // unary method back within reach of an attacker's page, so it is not a knob.
    final contentTypeValue = request.headers[RpcHeaders.contentType];
    if (!RpcSecurityPolicy.isAcceptableContentType(
      contentTypeValue,
      RpcContentTypeValidation.strict,
    )) {
      _logger?.warning(
        'Rejected request: unsupported Content-Type '
        '"${contentTypeValue ?? ''}" — expected application/grpc[+subtype]',
      );
      return _reject(415, request);
    }

    // `url`, not `requestedUri`: shelf's `url` is the path RELATIVE to wherever
    // this handler was mounted, and `requestedUri.path` is the whole thing. Mounted
    // under `/rpc/` — which this class's doc says three times it supports — the full
    // path is `/rpc/Echo/echo`, which is not a gRPC method path, so the documented
    // composition answered INVALID_ARGUMENT for every call.
    //
    // The leading slash is added back because `url` never carries one and
    // `parseRpcMethodPath` requires it. Unmounted the two forms are identical, which
    // is why nothing noticed.
    final methodPath = '/${request.url.path}';
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
      // One value per field line, as shelf combined it. A peer that sent a key
      // twice arrives here JOINED with ',' and is handed to the handler that way,
      // which is the same rule the caller's receive path follows: joined and
      // repeated are equivalent on the wire, and only the receiver knows whether
      // a given key's comma separates values or belongs inside one.
      final requestHeaders = <RpcHeader>[];
      request.headers.forEach((name, value) {
        requestHeaders.add(RpcHeader(name, value));
      });

      if (policy != null) {
        // The AGGREGATE bound. The per-header caps and `maxHeaders` do not imply
        // a total: their defaults together allow more than an order of magnitude
        // over `maxMetadataBytes`, every individual header legal.
        //
        // Counted here rather than left to the policy because each transport
        // knows its own byte count -- the frame channel bounds the serialized
        // payload, http2 the HPACK block, this one the header lines. Same rule,
        // applied where the number is real.
        var metadataBytes = 0;
        for (final h in requestHeaders) {
          // `name: value\r\n` is the wire form, so this undercounts by 4 per
          // header and can only ever reject later than the wire would.
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
      // a stall is bounded by [bodyIdleTimeout], the total by [bodyReadTimeout].
      //
      // BytesBuilder, not `List<int>` + `Uint8List.fromList`: a Dart list holds
      // WORD-SIZED elements, so the buffer costs several times the body and the
      // final copy doubles it again -- for a body size the PEER chooses, bounded
      // only by maxMessageLengthBytes. At the 16 MiB default that was hundreds
      // of MiB of peak for ONE accepted request.
      final idle = _IdleDeadline(bodyIdleTimeout);
      Future<Uint8List> readBody() async {
        final builder = BytesBuilder(copy: false);
        var exceeded = false;
        idle.arm();
        await for (final chunk in request.read()) {
          idle.arm();
          if (exceeded) continue;
          builder.add(chunk);
          // `maxBufferedBytes`, not the per-message limit: this body is a whole
          // client-stream UPLOAD, not one message. Identical by default --
          // `effectiveMaxBufferedBytes` falls back to `maxMessageLengthBytes +
          // 5`, which is what keeps a unary request at exactly the configured
          // limit acceptable where the bare message limit made the real ceiling
          // `max - 5`.
          if (policy != null &&
              builder.length > policy.effectiveMaxBufferedBytes) {
            exceeded = true;
            builder.clear();
          }
        }
        if (exceeded) {
          // The CONFIGURED number, not the framed one: see the bound above.
          throw _BodyTooLarge(
            policy!.maxBufferedBytes ?? policy.maxMessageLengthBytes,
          );
        }
        return builder.takeBytes();
      }

      var reading = Future.any([readBody(), idle.expired]);
      if (bodyReadTimeout != null) {
        reading = reading.timeout(
          bodyReadTimeout!,
          onTimeout: () => throw TimeoutException(
            'Body read timed out after $bodyReadTimeout',
            bodyReadTimeout,
          ),
        );
      }
      final Uint8List body;
      try {
        body = await reading;
      } finally {
        idle.cancel();
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
      // 413, not 400, for a body over the ceiling. `grpcStatusFromHttpStatus`
      // maps 413 -> RESOURCE_EXHAUSTED and 400 -> INTERNAL, so a 400 here tells
      // a peer something went wrong on this side rather than that its message
      // was too large -- and inverts the retry semantics with it, since
      // RpcRetryInterceptor retries RESOURCE_EXHAUSTED and nothing about
      // INTERNAL.
      final statusCode = switch (e) {
        TimeoutException() => 408,
        _BodyTooLarge() => 413,
        _ => 400,
      };
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _reject(
            statusCode,
            request,
            body: e is _BodyTooLarge ? '$e' : null,
            // The body reader has already run: see [_reject].
            drainBody: false,
          ),
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
    final pending = _pending.remove(streamId);
    // The shelf handler is AWAITING this completer. Dropping the entry without
    // completing it left the HTTP request open until the client gave up, with
    // the request object and the handler closure reachable behind it — and
    // health() reads `_pending`, so the drain saw an idle server with responses
    // still unwritten. Reached whenever a stream is torn down before it
    // answered: the pipeline's deadline reclaim is the ordinary way, and it
    // deliberately sends no trailer of its own.
    //
    // On every ORDINARY ending `_flushResponse` has already removed the entry,
    // so this cannot answer twice.
    if (pending != null && !pending.completer.isCompleted) {
      _logger?.warning(
        'Stream $streamId was released before it answered; closing the HTTP '
        'request with CANCELLED.',
      );
      pending.responseHeaders.addAll([
        RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.cancelled}'),
        RpcHeader(
          RpcHeaders.grpcMessage,
          'The call was torn down before the handler answered',
        ),
      ]);
      // CANCELLED, not DEADLINE_EXCEEDED: this method cannot know why the
      // stream was released, and the peer that set a deadline has already
      // reported one locally.
      _completeResponse(streamId, pending);
      return true;
    }
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
    if (pending.answered) return;
    pending.bodyBuffer.add(data);
    // HTTP/1.1 cannot flush before the end, so a server stream's WHOLE output
    // is resident until the handler finishes -- and a method that streams until
    // cancelled never does. Bounded by the same number the request side uses,
    // and for a stronger reason than symmetry: the caller refuses any body over
    // it, so every byte past this point is retained to be thrown away — the
    // caller receives nothing either way, and the only difference is how much
    // this side holds first.
    //
    // `maxBufferedBytes`, the same knob the two body reads use: this is a whole
    // STREAM, and bounding it by the per-message limit made raising the knob
    // whose name means "buffered bytes" do nothing.
    final limit = securityPolicy.effectiveMaxBufferedBytes;
    if (pending.bodyBuffer.length > limit) {
      _answerOversizedResponse(streamId, pending);
      return;
    }
    if (endStream) {
      await _flushResponse(streamId);
    }
  }

  /// Ends an over-budget response with RESOURCE_EXHAUSTED and stops buffering.
  ///
  /// The status rides ordinary response headers, which is where this wire
  /// format carries it; a 413 would be translated from the HTTP status instead
  /// and reaches the caller as whatever `grpcStatusFromHttpStatus` says today.
  void _answerOversizedResponse(int streamId, _PendingResponse pending) {
    pending.answered = true;
    pending.bodyBuffer.clear();
    _logger?.warning(
      'Response for [streamId: $streamId] exceeded '
      '${securityPolicy.maxBufferedBytes ?? securityPolicy.maxMessageLengthBytes} bytes and was ended early. '
      'HTTP/1.1 buffers a whole server stream before sending it.',
    );
    pending.responseHeaders.addAll([
      RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.resourceExhausted}'),
      RpcHeader(
        RpcHeaders.grpcMessage,
        'Response exceeds the ${securityPolicy.maxBufferedBytes ?? securityPolicy.maxMessageLengthBytes}-byte '
        'limit; HTTP/1.1 cannot stream it',
      ),
    ]);
    _completeResponse(streamId, pending);
  }

  @override
  Future<void> finishSending(int streamId) async {
    await _flushResponse(streamId);
  }

  Future<void> _flushResponse(int streamId) async {
    final pending = _pending.remove(streamId);
    if (pending == null) return;
    // Already answered over the ceiling; the entry was kept only so the
    // handler's remaining sends had somewhere quiet to land.
    if (pending.answered) return;

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Flushing HTTP response [streamId: $streamId]');
    }
    _completeResponse(streamId, pending);
  }

  /// The one `content-type` a gRPC response carries, echoing the request's
  /// subtype.
  ///
  /// gRPC's grammar is `application/grpc` followed by an OPTIONAL `+subtype`
  /// naming the body's encoding, and the subtype is the CALLER's choice: a
  /// client that asked for `+json` must not be told its answer is protobuf.
  /// Core cannot pick it — [RpcMetadata.forServerInitialResponse] has no
  /// request to look at and emits the bare form — so this transport owns the
  /// header, which is why [_completeResponse] drops the pipeline's copy.
  ///
  /// The request's value is REBUILT rather than echoed. It is peer input, and a
  /// response header is the one place a control character in it would matter.
  /// Anything that is not `application/grpc+<token>` degrades to the bare form,
  /// which is legal for every body — including the `; charset=...` that some
  /// proxies append, and the absent header that only a null policy admits.
  static String _responseContentType(String? requestContentType) {
    const bare = RpcHeaders.contentTypeGrpc;
    if (requestContentType == null) return bare;
    var value = requestContentType.toLowerCase();
    final parameters = value.indexOf(';');
    if (parameters >= 0) value = value.substring(0, parameters).trimRight();
    if (!value.startsWith('$bare+')) return bare;
    final subtype = value.substring(bare.length + 1);
    if (subtype.isEmpty) return bare;
    for (final unit in subtype.codeUnits) {
      final isLetter = unit >= 0x61 && unit <= 0x7A;
      final isDigit = unit >= 0x30 && unit <= 0x39;
      if (!isLetter && !isDigit && unit != 0x2E && unit != 0x2D) return bare;
    }
    return '$bare+$subtype';
  }

  /// Builds the shelf response from [pending] and completes its request.
  void _completeResponse(int streamId, _PendingResponse pending) {
    // Use Map<String, Object> to support multi-value headers (List<String>).
    final headers = <String, Object>{
      RpcHeaders.contentType: _responseContentType(
        pending.shelfRequest.headers[RpcHeaders.contentType],
      ),
    };

    if (corsPolicy != null) {
      final requestOrigin = pending.shelfRequest.headers['origin'];
      final corsHeaders = <String, String>{};
      corsPolicy!.applyTo(corsHeaders, requestOrigin);
      headers.addAll(corsHeaders);
    }

    for (final header in pending.responseHeaders) {
      if (header.name.startsWith(':')) continue;
      // `content-type` is the transport's, resolved above. Merging the
      // pipeline's bare `application/grpc` in through the branch below turned
      // the name into a TWO-element list: dart:io keeps the last, another shelf
      // adapter may put both on the wire, and the seeded value claimed `+proto`
      // for a `+json` call.
      if (header.name.toLowerCase() == RpcHeaders.contentType) continue;
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

  /// Requests accepted and not yet answered: what a graceful stop waits on.
  int get pendingRequests => _pending.length;

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
      details: {'pendingRequests': pendingRequests},
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

    // Complete any pending responses with 503. A request is pending only from
    // the synchronous stretch that ends in its body reader's `read()`, so the
    // drain is never ours to run here: see [_reject].
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _reject(503, pending.shelfRequest, drainBody: false),
        );
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

/// A deadline re-armed by every body chunk: [expired] fails once [limit]
/// passes with none. It RACES the read rather than cancelling it: cancelling
/// the body subscription makes dart:io drop the connection before the 408 goes
/// out, measured as `closed` instead of the status.
final class _IdleDeadline {
  _IdleDeadline(this.limit) {
    // Handled even when no read was ever raced against it.
    _expired.future.ignore();
  }

  final Duration? limit;
  final _expired = Completer<Never>();
  Timer? _timer;

  Future<Never> get expired => _expired.future;

  void arm() {
    final l = limit;
    if (l == null || _expired.isCompleted) return;
    _timer?.cancel();
    _timer = Timer(l, () {
      _expired.completeError(TimeoutException('No body bytes for $l', l));
    });
  }

  void cancel() => _timer?.cancel();
}
