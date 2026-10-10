// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'channel_transport.dart';

extension _ChannelTransportInbound on RpcChannelTransport {
  void _releaseStream(int streamId) {
    _activeStreams.remove(streamId);
    _idManager.releaseId(streamId);
  }

  void _onMessage(RpcTransportMessage incoming) {
    // The policy applies to INBOUND metadata. Validating only in sendMetadata
    // constrains this side's own honest sender and not the untrusted peer,
    // which is backwards for a security control: the frame layer bounds payload
    // length, so header count and size are bounded only here.
    var message = incoming;
    final asReceived = message.metadata;
    if (asReceived != null) {
      final checked = _validateInbound(asReceived, message.streamId);
      if (checked == null) return;
      // Rebuilt rather than mutated, and only when the policy reduced it: every
      // read below this point must see the same metadata the consumer will.
      if (!identical(checked, asReceived)) {
        message = RpcTransportMessage(
          streamId: message.streamId,
          payload: message.payload,
          directPayload: message.directPayload,
          metadata: checked,
          isEndOfStream: message.isEndOfStream,
          methodPath: message.methodPath,
        );
      }
    }
    final metadata = message.metadata;

    // Recorded BEFORE dispatch, because trailers arrive as a metadata frame
    // that is itself the end of the stream.
    //
    // Gated on a per-stream controller, which exists only on LOCAL initiative.
    // The id is the peer's choice, exactly like the flow-control maps above,
    // and those are capped for that reason; this set is read only for an id
    // that has a controller (see `truncatedEnd` below), so gating it there
    // bounds it by our own traffic instead. Ungated, a peer can grow it without
    // limit with metadata-only frames on ids we never minted -- frames the
    // responder pipeline ignores as no-ops, so nothing above the transport ever
    // sees them.
    if (metadata != null &&
        _streamControllers.containsKey(message.streamId) &&
        metadata.getHeaderValue(RpcHeaders.grpcStatus) != null) {
      _statusSeen.add(message.streamId);
    }

    // A grant is transport bookkeeping, not part of the call: consume it here
    // so no upper layer ever sees it.
    if (_fc.handleInbound(message)) return;

    // Tell the peer our window as soon as it opens a stream. Until this lands
    // the peer sends unbounded, which is what keeps an unaware peer working.
    //
    // **Measure that on the right side.** A probe using ONE policy for both
    // ends reports a 186x blow-up, because the flood fills the SENDER's own
    // credit map and the unbounded send is self-inflicted.
    _fc.advertiseConnection();
    _fc.advertiseStream(message.streamId);

    // A response that ends with no grpc-status is TRUNCATED, and the end flag
    // must not reach the consumer: it would close the stream cleanly and the
    // error raised below would arrive too late to be seen. Any payload the
    // frame carries is still delivered; only the end marker is withheld.
    //
    // CLIENT SIDE ONLY. A grpc-status travels server -> client, so a client's
    // ordinary half-close carries none and is not truncation. Apply this on the
    // responder and every request stream's end looks truncated.
    final truncatedEnd =
        isClient &&
        message.isEndOfStream &&
        !_statusSeen.contains(message.streamId);

    // Per-stream controllers are single-subscription and buffer until their
    // consumer binds, so route there directly.
    //
    // NOT when a higher layer has claimed the metering. A client-stream
    // responder is fed by the pipeline (`_pipelineFedRequestStream`), which
    // deliberately does not subscribe to `getMessagesForStream` — so for those
    // streams this controller has NO consumer, and routing through it is not
    // merely wasted:
    //
    //   * `_admitToStreamBuffer` charges every message against the bound and
    //     the charge is released only by `_fcMetered`, which is that same
    //     unsubscribed path, so it only ever grows;
    //   * over the bound the message is REFUSED, and the refusal returns before
    //     `_incoming.add` — so the pipeline never sees the message either;
    //   * the error it raises goes into that unread controller.
    //
    // A request then vanishes between two peers that both report success,
    // which is what a consumer measured: 17 messages handed to `send()`, 16
    // given to the handler, no error on either side. A stream whose credit is
    // deferred takes the branch below instead, where it is accounted for and
    // dispatched.
    final ctl = _fc.isDeferred(message.streamId)
        ? null
        : _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) {
      // Credited by _metered when the consumer takes it; outstanding against
      // the connection pool until then, and repaid if it never does. A refused
      // message is dropped, so its bytes go straight back to the pool, or the
      // refusal wedges every other stream's sender.
      final bytes = message.payload?.length ?? 0;
      if (!_admitToStreamBuffer(message, ctl)) {
        if (bytes > 0) _fc.credit(message.streamId, bytes);
        return;
      }
      _fc.oweConnection(message.streamId, bytes);
      if (!truncatedEnd) {
        ctl.add(message);
      } else if (message.payload != null || message.isDirect) {
        ctl.add(
          RpcTransportMessage(
            streamId: message.streamId,
            payload: message.payload,
            directPayload: message.directPayload,
            metadata: message.metadata,
            methodPath: message.methodPath,
          ),
        );
      }
    } else if (_fc.isDeferred(message.streamId)) {
      // A higher layer claimed the metering (IRpcFlowControlled), so the same
      // debt applies -- settled by returnFlowCredit as it consumes, repaid at
      // teardown for whatever it does not.
      _fc.oweConnection(message.streamId, message.payload?.length ?? 0);
    } else {
      // Nothing meters this one and no layer has claimed it, so it goes
      // straight into the pipeline's own buffers and is consumed as soon as it
      // is dispatched. Crediting on arrival keeps such a stream from stalling
      // at the window, at the cost of not bounding it.
      _fc.onConsumed(message.streamId, message);
    }
    // Global dispatch exists for NEW-STREAM ROUTING: the responder pipeline
    // discovers a peer-initiated call here, and the buffered controller retains
    // the message if that pipeline has not subscribed yet rather than dropping
    // it. A response on a stream WE opened is already routed to its own
    // controller above, so broadcasting it serves nobody.
    //
    // Broadcasting it is not free either. The controller buffers while
    // unlistened, and a caller-only endpoint has nothing to do with these events,
    // so `startCallerListening` subscribes a no-op listener purely to keep the
    // buffer drained — where that is missed, it retains every response the caller
    // already consumed.
    //
    // Errors are unaffected: a channel failure or a policy violation with no
    // known stream goes through `_incoming.addError`, which this does not touch,
    // so the caller's observer still has something to observe.
    final locallyInitiated = _idManager.isClient
        ? message.streamId.isOdd
        : message.streamId.isEven;
    final wasRouted = ctl != null && !ctl.isClosed;
    if (!(locallyInitiated && wasRouted)) {
      _incoming.add(message);
    }
    if (message.isEndOfStream) {
      // Only for a stream WE opened, where an inbound end-of-stream is the
      // response's last frame and so the end of the call. On one the PEER
      // opened it is their half-close and we may still be sending the whole
      // response — dropping the flow-control state there leaves every later
      // grant looking like one for a call that has ended, so `_onGrant`
      // discards it and the per-stream window never engages again. A server
      // stream half-closes its request immediately, so that is every server
      // stream. The state is pruned by `releaseStreamId` when the call really
      // ends, which the responder pipeline always calls.
      if (locallyInitiated) {
        _releaseStream(message.streamId);
        _finishedStreams.remove(message.streamId);
        _forgetStream(message.streamId);
      } else {
        // The INBOUND half is over and nothing more will arrive on it, so what
        // it owes the pool is owed for good — repaying it here is what keeps a
        // handler that never read from draining the connection window. The
        // send-side state is NOT the inbound half's to drop.
        _fc.repayConnection(message.streamId);
      }
      // A truncated response is an ERROR, not a clean end: a clean end hands
      // the consumer partial data as if it were complete, and a client paging
      // results believes it has them all.
      //
      // This only holds because rpc_dart's own teardown and deadline paths
      // always send a status now (see the ping handler and _cleanupStream). Let
      // any of them end a stream status-lessly again and every such teardown
      // starts reporting UNAVAILABLE to its own caller.
      _statusSeen.remove(message.streamId);
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) {
        if (truncatedEnd) {
          // INTERNAL, not UNAVAILABLE: the difference is whether the call is
          // RETRIED. The request reached a peer that answered and then ended
          // without its status, so the work may have run -- measured with
          // `maxAttempts: 3`, the peer served one unary call THREE times.
          // UNAVAILABLE is what `RpcRetryInterceptor` retries by design and
          // belongs to a connection that died, not to a peer that forgot.
          ended.addError(
            RpcStatusException(
              RpcStatus.internal,
              'Stream ended without a gRPC status (truncated response)',
            ),
          );
        }
        // Closed after the error is enqueued, so the subscriber observes the
        // final message, then the error, then done.
        unawaited(ended.close());
      }
    }
  }
}
