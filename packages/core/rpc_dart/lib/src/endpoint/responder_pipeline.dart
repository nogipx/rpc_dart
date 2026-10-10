// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// The header-value cap a trailer about to leave through [transport] will be
/// judged by.
///
/// Every outbound trailer needs it, because `grpc-message` is a header value:
/// one longer than the cap fails validation and the whole answer is lost, so
/// the peer gets silence or a generic fallback instead of the status. Round 175
/// fixed the sites that call `RpcMetadata.forTrailer`, and the two that built
/// the headers BY HAND were missed for exactly that reason -- they did not match
/// the grep. This exists so there is one way to ask.
int _trailerMessageCap(IRpcTransport transport) =>
    _policyOfTransport(transport).maxHeaderValueBytes;

/// The policy [transport] carries, or the defaults when it carries none.
///
/// Read through [IRpcSecurityPolicyAware] rather than a second knob, so a
/// transport without that capability gets the safe default.
RpcSecurityPolicy _policyOfTransport(IRpcTransport transport) =>
    transport is IRpcSecurityPolicyAware
    ? (transport as IRpcSecurityPolicyAware).securityPolicy
    : const RpcSecurityPolicy();

/// Mixin providing the responder (incoming request handler) pipeline.
///
/// Manages method registration, incoming message routing, responder creation,
/// and stream lifecycle. Concrete endpoints control which messages enter
/// the pipeline via [startResponderListening]'s optional [messageFilter].
base mixin RpcResponderPipelineMixin on RpcEndpointBase {
  /// Runs detached teardown work that must never take the process with it.
  ///
  /// Every path below is a cleanup: a cancellation, a drain, a rejected
  /// stream. None of them has a caller left to report to, which is why they
  /// are detached in the first place — and that is exactly what made them
  /// lethal. A bare `unawaited` sends any throw to the zone, and a server with
  /// no zone error handler dies on it.
  ///
  /// Observed in production: a client abandoning a coalesced blob download
  /// cancels with its own reason, `_handleClientCancellation` cancels the
  /// server-side token with that reason, the aborted handler raises
  /// `RpcCancelledException` — and both replicas exited 255 within hours of
  /// each other. A client must not be able to end a server by hanging up.
  void _detached(Future<void> work, String what) {
    unawaited(
      work.catchError((Object e, StackTrace st) {
        _log.warning('detached $what failed: $e');
      }),
    );
  }

  /// Dispatches a responder, turning a failure into an answer rather than a
  /// dead process.
  ///
  /// Deliberately NOT [_detached]: this is the handler being bound, not a
  /// teardown, and swallowing here would hide a real fault. The peer is still
  /// waiting, so the failure is reported to it as INTERNAL and the stream is
  /// cleaned up — which is what would have happened had the throw been
  /// synchronous.
  void _detachedDispatch(Future<void> work, RpcResponderStreamState state) {
    unawaited(
      work.catchError((Object e, StackTrace st) {
        _log.warning("responder dispatch failed for stream ${state.id}: $e");
        _detached(
          _sendGrpcErrorAndCleanup(
            streamId: state.id,
            status: RpcStatus.internal,
            message: 'Responder dispatch failed',
            context: state.cachedContext,
          ),
          'dispatch failure report',
        );
      }),
    );
  }
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final RpcResponderMethodRegistry _respRegistry = RpcResponderMethodRegistry();
  final RpcResponderStreamStore _respStreams = RpcResponderStreamStore();
  StreamSubscription<RpcTransportMessage>? _respIncomingSub;
  bool _respIsListening = false;

  /// The filter the live subscription was started with, so a later call asking
  /// for a different one can be told its filter is being ignored.
  bool Function(RpcTransportMessage)? _respMessageFilter;
  bool _respIsDraining = false;

  /// The drain currently in progress, shared by every concurrent caller.
  Future<void>? _respDrainInFlight;

  /// Completed by [_cleanupStream] when the last active stream goes away, so
  /// [_runDrain] can wait to be told rather than poll for it.
  Completer<void>? _respDrainIdle;

  /// Stream ids already torn down.
  ///
  /// Tearing a stream down does not stop the peer: its request payload races
  /// our error trailer, and a cancelled or completed call can be followed by
  /// trailing frames. Without this guard those frames reach
  /// `_respStreams.obtain()` and RESURRECT state nothing will clean up again —
  /// the revived entry has no method, so it buffers the frame and sits there,
  /// one per call, driven by any peer that calls an unregistered method.
  ///
  /// Insertion-ordered, so evicting `first` drops the oldest; bounded so this
  /// guard cannot become a leak of its own.
  final Set<int> _respClosedStreams = <int>{};

  /// How many torn-down stream ids to remember. Late frames arrive right after
  /// the teardown, so a modest window covers the race.
  static const int _maxRememberedClosedStreams = 1024;

  /// Cached concurrent-stream ceiling for streams the PEER opens.
  ///
  /// `createStream()` checks `maxActiveStreams` for LOCALLY-initiated calls
  /// only, so without this the inbound streams — the only ones an untrusted
  /// peer controls — are counted by nothing.
  ///
  /// Read through [IRpcSecurityPolicyAware] rather than a second knob, so a
  /// transport without that capability gets the safe default.
  int? _respMaxStreamsCache;

  int get _respMaxStreams =>
      _respMaxStreamsCache ??= _policyOfTransport(transport).maxActiveStreams;

  /// Un-consumed request bytes held for handlers, per stream and per
  /// connection. The connection ceiling is the connection window: an honest
  /// peer cannot have more outstanding than it was granted.
  RpcResponderBufferBudget? _respBudgetCache;

  /// What one queued request message retains beyond its payload bytes.
  static const int _heldMessageOverheadBytes = 128;

  RpcResponderBufferBudget get _respBudget {
    final cached = _respBudgetCache;
    if (cached != null) return cached;
    final transport = this.transport;
    final policy = _policyOfTransport(transport);
    final noDepth = transport is IRpcNoMessageCredit;
    return _respBudgetCache = RpcResponderBufferBudget(
      streamBytes: policy.effectiveStreamBufferBytes,
      // No depth where the peer cannot be told it; see IRpcNoMessageCredit.
      // 2^30, not a larger int: the budget's arithmetic must hold on dart2js.
      streamEvents: noDepth ? 1 << 30 : policy.maxBufferedMessagesPerStream,
      // In its place each message weighs what it retains, or the byte totals
      // cannot see a queue of tiny messages.
      perMessageBytes: noDepth ? _heldMessageOverheadBytes : 0,
      connectionBytes: policy.effectiveConnectionBufferBytes,
      shared: transport is IRpcConnectionBufferTotal
          ? transport as IRpcConnectionBufferTotal
          : null,
    );
  }

  /// The policy's rule for a request carrying no `content-type` at all.
  ///
  /// Same shape as [_respMaxStreams]: a transport that cannot carry a policy
  /// gets the default, which is the value every channel transport used before
  /// this was configurable.
  RpcContentTypeValidation get _respContentTypeValidation =>
      _policyOfTransport(transport).contentTypeValidation;

  /// Streams holding a handler-concurrency slot: dispatched, work not finished.
  ///
  /// Deliberately NOT [_respStreams], which goes away too early. A handler that
  /// ignores its cancellation token cannot be preempted, so a stream reclaimed
  /// after its deadline takes the state and leaves the work — counting streams
  /// then reports a small number while many handlers run. See
  /// [RpcSecurityPolicy.maxConcurrentHandlers].
  ///
  /// Bounded by the ceiling itself: an id is only added after the length check
  /// passes, and a Set makes a double charge for one stream impossible.
  final Set<int> _respSlotHeld = {};

  /// Streams whose handler is executing right now. A slot outlives this set
  /// only in the other direction: charged at admission, held until the handler
  /// finishes even if the stream died first.
  final Set<int> _respHandlerLive = {};

  int? _respMaxHandlersCache;
  bool _respMaxHandlersResolved = false;

  int? get _respMaxHandlers {
    if (_respMaxHandlersResolved) return _respMaxHandlersCache;
    _respMaxHandlersResolved = true;
    return _respMaxHandlersCache = _policyOfTransport(
      transport,
    ).maxConcurrentHandlers;
  }

  /// Bytes parked across every stream whose method is still unknown.
  ///
  /// A frame with no resolved method is buffered rather than dropped, because a
  /// broadcast transport can deliver a stream's first DATA frame before its
  /// metadata. Nothing else bounds that window: until the responder is bound no
  /// layer claims the stream, so flow control credits ON ARRIVAL and the peer's
  /// window refills forever; `maxActiveStreams` sees one id, and
  /// `maxMessageLengthBytes` sees frames that are each individually legal.
  ///
  /// **Counted per connection, not per stream** — otherwise inventing stream
  /// ids buys more budget.
  int _respPreMethodBytes = 0;

  /// Whether the "repeat opening frame" notice has gone out.
  ///
  /// Once. A peer that sends one sends it on every call, and the interesting
  /// fact is that it happens at all.
  bool _warnedRepeatOpeningFrame = false;

  /// Each refusal below is something a peer can repeat on every stream it
  /// opens, so each warns once per connection; the peer gets its status either
  /// way.
  bool _warnedHalfOpen = false;
  bool _warnedNoOpFrame = false;
  bool _warnedAdvisoryError = false;
  bool _warnedStreamLimit = false;
  bool _warnedPreMethod = false;
  bool _warnedPreBind = false;
  bool _warnedHandlerLimit = false;

  /// Ceiling for [_respPreMethodBytes].
  ///
  /// [RpcSecurityPolicy.maxMessageLengthBytes] rather than a new knob: the
  /// buffer exists to cover a frame-REORDER window, so one maximum message's
  /// worth across the whole connection is already orders of magnitude more than
  /// the legitimate case (a single leading chunk that overtook its headers)
  /// ever needs, and it is the limit an operator already tunes for "how big may
  /// one thing be". A breach fails only the stream that overflowed the budget.
  int? _respMaxPreMethodCache;

  int get _respMaxPreMethodBytes => _respMaxPreMethodCache ??=
      _policyOfTransport(transport).maxMessageLengthBytes;

  /// Cached half-open reclamation window, read from the transport's policy.
  Duration? _respHalfOpenCache;
  bool _respHalfOpenResolved = false;

  Duration? get _respHalfOpenTimeout {
    if (_respHalfOpenResolved) return _respHalfOpenCache;
    _respHalfOpenResolved = true;
    return _respHalfOpenCache = _policyOfTransport(
      transport,
    ).halfOpenStreamTimeout;
  }

  void _rememberClosedStream(int streamId) {
    if (!_respClosedStreams.add(streamId)) return;
    if (_respClosedStreams.length > _maxRememberedClosedStreams) {
      _respClosedStreams.remove(_respClosedStreams.first);
    }
  }

  /// Whether the responder pipeline is currently listening.
  bool get responderIsListening => _respIsListening;

  /// Built per ping, which is rare, so it logs to the endpoint's CURRENT scope:
  /// `RpcResponderEndpoint.setLogController` replaces that scope after
  /// construction, and a handler built once kept the old one.
  RpcResponderPingHandler get _respPingHandler => RpcResponderPingHandler(
    transport: transport,
    logger: _log,
    debugLabel: debugLabel,
  );

  // ---------------------------------------------------------------------------
  // Contract registration
  // ---------------------------------------------------------------------------

  /// Registers [contract] so its methods can handle incoming requests.
  ///
  /// A contract's lifetime is the endpoint's, and a server endpoint's lifetime
  /// is ONE CONNECTION. Closing the endpoint calls `dispose()` on every
  /// contract registered here, so a contract may own only what it created for
  /// that connection. Anything shared — a database pool, a notify repository,
  /// an application singleton from a container — is borrowed, and disposing it
  /// from a contract takes the resource away from every other connection.
  ///
  /// This became load-bearing when the transport servers started closing a
  /// dropped connection's endpoint instead of leaking it: `dispose()` went
  /// from never running to running on every disconnect. The first contract
  /// that was disposing a shared repository took a production notify bus down
  /// with it, silently, on the first client that went away.
  void registerServiceContract(RpcResponderContract contract) {
    _respRegistry.registerContract(contract, _log);
  }

  /// Removes the contract for [serviceName] and disposes its resources.
  void unregisterServiceContract(String serviceName) {
    _respRegistry.unregisterContract(serviceName, _log);
  }

  /// All contracts registered with this endpoint, keyed by service name.
  Map<String, RpcResponderContract> get registeredContracts =>
      _respRegistry.contracts;

  /// All method bindings keyed by `serviceName.methodName`.
  Map<String, RpcResponderMethodBinding> get registeredMethodBindings =>
      _respRegistry.methods;

  // ---------------------------------------------------------------------------
  // Listening lifecycle
  // ---------------------------------------------------------------------------

  /// Starts listening to incoming messages.
  ///
  /// When [messageFilter] is provided, only messages for which it returns true
  /// enter the responder pipeline. This is used by [RpcPeerEndpoint] to filter
  /// by stream ID parity.
  Future<void> startResponderListening({
    bool Function(RpcTransportMessage)? messageFilter,
  }) async {
    if (_respIsListening) {
      // Starting twice is ORDINARY, not a mistake: `RpcWebSocketServer` calls
      // `onEndpointCreated` and then `start()`, and the framework's callback
      // registers the contracts and starts it too — so every connection took
      // this branch. Measured on a consumer's two replicas: 704 and 698 of
      // these warnings in 24 h, against 6 and 34 lines of real error, which is
      // the ratio that makes a log unreadable during an incident.
      //
      // What IS a mistake is a second call asking for a DIFFERENT filter: the
      // first one stays, so the caller silently does not get the filtering it
      // asked for. That keeps the warning; the redundant call loses it.
      if (messageFilter != _respMessageFilter) {
        _log.warning(
          'Already listening for incoming requests, and this call asks for a '
          'different messageFilter — the first one stays in effect',
        );
      } else {
        _log.internal('Already listening for incoming requests');
      }
      return;
    }
    _respMessageFilter = messageFilter;
    // Claimed BEFORE the first await, not after the subscribe below. `start()`
    // returns void and nobody awaits it, so two synchronous calls otherwise
    // both pass the guard, both suspend on the cancel below, and both
    // subscribe. The incoming stream is a BROADCAST, so that is two live
    // subscriptions delivering every frame twice, the first of them orphaned --
    // and only a call shape that ACCUMULATES requests shows it, since one
    // request frame is deduplicated downstream.
    _respIsListening = true;

    final oldSub = _respIncomingSub;
    _respIncomingSub = null;
    await oldSub?.cancel();

    _respIncomingSub = transport.incomingMessages.listen(
      (message) {
        if (messageFilter != null && !messageFilter(message)) return;
        _processResponderMessage(message);
      },
      onError: (Object error, StackTrace stackTrace) {
        // An advisory error is an OBSERVATION, not a failure: a proxy's
        // app-level keepalive arriving as a text frame, one stream's metadata
        // over the policy. The connection still works, so answering it would
        // fail every call in flight for nothing -- and the peer sends one per
        // frame, so it is reported once, not at error per frame.
        if (error is IRpcAdvisoryChannelError) {
          if (!_warnedAdvisoryError) {
            _warnedAdvisoryError = true;
            _log.warning(
              'Transport reported a discarded frame (logged once per '
              'connection): $error',
            );
          }
          return;
        }
        _log.error(
          'Transport incoming error',
          error: error,
          stackTrace: stackTrace,
        );

        // ANSWER it. This used to LOG ONLY, and the duty was carried instead by
        // one subscription per live unary handler, each on this same
        // connection-wide broadcast -- O(N) listeners invoked per frame to
        // answer an error that arrives once. Done here it is one pass.
        //
        // `onDone` is the other ending and stays separate: there the transport
        // is gone, so there is nothing to answer over and _abortActiveStreams
        // only has to reclaim. This path is a transport error that did NOT
        // close the stream, where the caller is still reachable and otherwise
        // waits out its own deadline for a failure we could name.
        _detached(_answerActiveStreams(error), 'transport error');
      },
      onDone: () {
        _log.internal('Transport incoming stream closed');
        _abortActiveStreams('transport closed');
      },
    );
  }

  /// Stops listening and releases all responder resources.
  ///
  /// Cancels the tokens before tearing the streams down, like every other
  /// teardown path here. Without it this was the ONE way a stream ended without
  /// its handler being told: a handler that polls `cancellationToken` or awaits
  /// `cancelled` kept running after `endpoint.close()` returned, against
  /// controllers that were already gone.
  Future<void> closeResponderResources() async {
    await _respIncomingSub?.cancel();
    _respIncomingSub = null;
    _respIsListening = false;

    for (final state in _respStreams.values) {
      final token = state.cachedContext?.cancellationToken;
      if (token != null && !token.isCancelled) token.cancel('endpoint closed');
    }

    final activeStreamIds = _respStreams.values
        .map((s) => s.id)
        .toList(growable: false);
    for (final streamId in activeStreamIds) {
      await _cleanupStream(streamId);
    }

    _respRegistry.disposeAll(_log);
  }

  /// Whether the endpoint is draining (rejecting new streams, finishing active ones).
  bool get isDraining => _respIsDraining;

  /// Stops admitting NEW streams, leaving the active ones alone.
  ///
  /// The half of [drain] a graceful shutdown actually wants. From here a new
  /// stream is answered `UNAVAILABLE` — retryable, which is what a draining
  /// server should say — while anything already running finishes on its own.
  ///
  /// It exists because the two halves had no separate switch, and a server that
  /// wanted only this had no way to ask for it. `RpcWebSocketServer` is that
  /// server: WebSocket has no GOAWAY, so without an admission stop its
  /// `stop(drainTimeout:)` did not drain at all — it waited, serving everything
  /// an already-connected peer asked for. Measured against http2, which does
  /// send GOAWAY, with both budgets fully spent:
  ///
  ///     websocket  1347 calls admitted after shutdown began
  ///     http2         4
  ///
  /// Not idempotent-sensitive and deliberately not a `Future`: it sets a flag.
  /// Wait for the work with [drainUntilIdle] or [drain].
  @override
  void markDraining() => _respIsDraining = true;

  @override
  int get activeResponderCount =>
      _respStreams.values.where((state) => state.hasResponder).length;

  /// Initiates graceful drain: rejects new streams and cancels active contexts.
  ///
  /// After calling [drain], new incoming streams receive `UNAVAILABLE` status.
  /// Active streams have their cancellation tokens triggered with reason
  /// "server draining", giving handlers a chance to finish gracefully.
  ///
  /// Returns a [Future] that completes when all active streams have finished,
  /// or when [timeout] expires (whichever comes first).
  ///
  /// Concurrent callers share one drain and ALL await the same completion.
  /// Returning early for the later ones lets a second caller walk past the
  /// drain and tear down what it was protecting, which is the one thing this
  /// exists to prevent — and re-entry needs only two shutdown paths racing, a
  /// signal handler and an explicit stop.
  ///
  /// A later caller's [timeout] does not apply: the drain in progress keeps the
  /// deadline it started with, since one drain cannot honour two.
  Future<void> drain({Duration timeout = const Duration(seconds: 30)}) {
    return _respDrainInFlight ??= _runDrain(timeout);
  }

  /// Collects responder-specific metrics.
  ///
  /// Everything about responder streams belongs HERE, not in one endpoint
  /// subclass: both [RpcResponderEndpoint] and [RpcPeerEndpoint] serve calls
  /// through this mixin, and a server's graceful drain polls `activeResponders`
  /// to decide whether anything is still running. Published by the responder
  /// alone, that poll read null for a peer endpoint and shut the server down on
  /// top of live calls.
  Map<String, Object?> collectResponderMetrics() {
    return {
      'registeredContracts': _respRegistry.contracts.length,
      'registeredMethods': _respRegistry.methods.length,
      'isListening': _respIsListening,
      'isDraining': _respIsDraining,
      'openStreams': _respStreams.length,
      // Un-attributed payload parked on this connection. Should sit at 0
      // between calls; a number that only ever climbs means the budget is not
      // being released and legitimate calls will start being refused.
      'preMethodBufferedBytes': _respPreMethodBytes,
      'metadataStreams': _respStreams.values
          .where((state) => state.hasMetadata)
          .length,
      'bufferedMessages': _respStreams.values
          .where((state) => state.lastPayloadMessage != null)
          .length,
      'clientStreamBuffers': _respStreams.values
          .where((state) => state.hasBufferedClientMessages)
          .length,
      // The metrics key and the drain now read ONE source. The key is
      // observability and free to rename; the count is a shutdown decision.
      'activeResponders': activeResponderCount,
      if (_respRegistry.contracts.isNotEmpty)
        'contractKeys': List<String>.unmodifiable(_respRegistry.contracts.keys),
    };
  }

  /// The [RpcRetryInfo] a capacity refusal carries, so a caller's retry policy
  /// can tell it from a size refusal with the same status.
  static final Uint8List _capacityDetails = RpcStatusException.atCapacity(
    '',
  ).statusDetailsBin!;

  Future<void> _sendGrpcErrorAndCleanup({
    required int streamId,
    required int status,
    required String message,
    RpcContext? context,
    List<RpcHeader> extraHeaders = const [],
    bool atCapacity = false,
  }) async {
    // SYNCHRONOUSLY, before the first await, and that is the whole fix.
    //
    // `_cleanupStream` in the `finally` below already remembers the id — but
    // every refusal site calls this through `_detached`, so the remembering
    // happened a microtask later than the next inbound frame. A call opened with
    // metadata AND payload is two frames: both found no stream, both fell through
    // the same checks, and both were refused. TWO terminal statuses on one
    // stream, which is a protocol violation anywhere the peer keeps stream state.
    //
    // Measured on a channel pair, before:
    //
    //     draining, a NEW call (2 frames)   [status=14, status=14]
    //     ceiling 1, a 2nd call (2 frames)  [status=8,  status=8]
    //
    // One site rather than the sixteen call sites, because the race is not in any
    // of them: it is in the gap between deciding to refuse and recording that the
    // id is done. Suppressing the second SEND instead would leave the refusal
    // path still treating a refused stream as unknown, and the next frame type
    // would find the same hole.
    _rememberClosedStream(streamId);
    try {
      // Trimmed to the policy this trailer is about to be validated against;
      // see RpcMetadata.forTrailer. The status is what must reach the peer.
      final trailer = RpcMetadata.forTrailer(
        status,
        message: message,
        maxMessageLength: _trailerMessageCap(transport),
        statusDetailsBin: atCapacity ? _capacityDetails : null,
      );
      await transport.sendMetadata(
        streamId,
        extraHeaders.isEmpty
            ? trailer
            : RpcMetadata([...trailer.headers, ...extraHeaders]),
        endStream: true,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Failed to send gRPC error [$status] for streamId=$streamId',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _cleanupStream(streamId);
    }
  }

  /// The stream a call's starting token belongs to, for [_handlerContextChosen].
  /// An Expando, so it holds nothing once the call is gone.
  final Expando<RpcResponderStreamState> _streamByToken = Expando();

  /// Enforces a deadline a responder interceptor set, when it is EARLIER than
  /// the one already armed: the timer above was armed from the inbound
  /// message, before any interceptor ran, so without this a server-side
  /// timeout written as an interceptor changed what the handler read and
  /// nothing else. A later deadline, or none, leaves the caller's in force --
  /// a responder may shorten a call, never extend what the caller asked for.
  ///
  /// A call this endpoint MAKES has no entry here, so on a peer the outgoing
  /// half is untouched.
  @override
  void _handlerContextChosen(RpcCancellationToken? origin, RpcContext ctx) {
    if (origin == null) return;
    final state = _streamByToken[origin];
    final chosen = ctx.deadline;
    if (state == null || chosen == null) return;
    if (!identical(_respStreams[state.id], state)) return;
    final armed = state.deadlineAt;
    if (armed != null && !chosen.isBefore(armed)) return;
    state.deadlineAt = chosen;
    state.armDeadline(
      chosen.difference(ctx.clock()),
      () => _onDeadlineExceeded(state),
    );
  }

  /// How long past the deadline reclamation waits. See
  /// [RpcResponderStreamState.armReclaim] for why it cannot be immediate.
  static const Duration _reclaimGrace = Duration(seconds: 2);

  /// Cancels the handler via its cancellation token — the path [drain] uses —
  /// and then ENDS the stream once [_reclaimGrace] has passed.
  ///
  /// The teardown is a backstop, not the mechanism: a cooperative handler
  /// unwinds long before the grace elapses and cleans up the usual way. What it
  /// covers is the handler that ignores the token, which Dart cannot preempt
  /// and which would otherwise pin its stream state and responder forever.
  ///
  /// WHAT THAT COSTS: [_cleanupStream] frees the stream STATE and the admission
  /// slot together. For an uncooperative handler the first is right and the
  /// second is not — the work is still running with its slot back in the pool,
  /// so [RpcSecurityPolicy.maxActiveStreams] stops bounding concurrent
  /// execution and `activeResponders` reads far below the real number. That is
  /// the price of not leaking; charging the slot until the handler's future
  /// completes would close it, at the cost of turning a slow server into a
  /// rejecting one. Recorded on [RpcSecurityPolicy.maxActiveStreams] too, where
  /// someone configuring a server will read it.
  ///
  /// Answers DEADLINE_EXCEEDED, as gRPC does, and ends the stream at once.
  /// Without it a cooperative handler unwound with its token's CANCELLED, and a
  /// server stream often sent nothing at all: a peer that relies on the
  /// server's answer -- a foreign client, a proxy -- read the wrong status or
  /// waited forever. The rpc_dart caller reaches the same deadline locally;
  /// it maps this trailer to the same [RpcDeadlineExceededException], so the
  /// race between the two cannot change what it raises.
  void _onDeadlineExceeded(RpcResponderStreamState state) {
    _detached(
      _sendGrpcErrorAndCleanup(
        streamId: state.id,
        status: RpcStatus.deadlineExceeded,
        message: 'Deadline exceeded',
        context: state.cachedContext,
      ),
      'grpc error cleanup',
    );
    final token = state.cachedContext?.cancellationToken;
    if (token != null && !token.isCancelled) {
      token.cancel('deadline exceeded');
    }
    if (_log.isInternal) {
      _log.internal(
        'Stream ${state.id} exceeded its deadline — cancelling handler',
      );
    }

    // Cancelling the token is only a REQUEST to stop, and Dart cannot preempt a
    // handler that ignores it. Without this backstop such a handler pins its
    // stream state and responder forever, on every call shape -- and with
    // maxActiveStreams enforced that leak becomes a hard outage at the ceiling.
    state.armReclaim(_reclaimGrace, () {
      if (!identical(_respStreams[state.id], state)) return;
      _log.warning(
        'Stream ${state.id} still open ${_reclaimGrace.inSeconds}s after its '
        'deadline — reclaiming',
      );
      _detached(_cleanupStream(state.id, only: state), 'stream cleanup');
    });
  }
}
