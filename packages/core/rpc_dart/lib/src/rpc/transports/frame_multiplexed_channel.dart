// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import '../../core/_index.dart';

/// [IRpcMultiplexedChannel] that wraps a raw [IRpcChannel] with frame encoding.
///
/// Encodes outgoing [RpcTransportMessage] into [RpcChannelFrame] bytes and
/// decodes incoming bytes back into messages. Handles partial-frame reassembly
/// via an internal read buffer.
///
/// Use [pair] for testing without a real byte transport.
class RpcFrameMultiplexedChannel
    implements IRpcMultiplexedChannel, IRpcChannelProtocolClose {
  final IRpcChannel _channel;
  final RpcSecurityPolicy _policy;

  /// Buffered, like every other inbound controller in the library.
  ///
  /// This class starts decoding from its own constructor, so anything arriving
  /// before the transport subscribes is retained rather than dropped. Nothing
  /// loses a frame today — `fromChannel` builds channel and transport in one
  /// expression — but that is an ordering property of a constructor, not an
  /// invariant, and this type is public and documented for direct construction.
  final BufferedBroadcastController<RpcTransportMessage> _incomingCtl =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );
  StreamSubscription<Uint8List>? _channelSub;

  /// Growable reassembly buffer. Valid data is `_buf[0.._bufLen)`; capacity may
  /// exceed [_bufLen]. Appends grow capacity geometrically, so a peer dribbling
  /// one frame across many tiny chunks costs O(n) rather than the O(n^2) of
  /// reallocating and recopying per chunk.
  Uint8List _buf = Uint8List(0);
  int _bufLen = 0;
  bool _closed = false;

  /// Bytes still to discard from a frame that is too big for us to buffer.
  ///
  /// A declared payload over the ceiling is the one framing fault whose next
  /// frame boundary is known EXACTLY -- the header says where it is -- so it is
  /// answered on its own stream and stepped over, instead of taking the
  /// connection down with it. Nothing is buffered while skipping, so the
  /// allocation bound [_onData] enforces is unchanged.
  int _skipRemaining = 0;

  /// Stream the bytes being skipped belong to, so their credit is returned
  /// against the right one.
  int _skipStreamId = 0;

  /// Whether an oversized inbound frame kills the connection.
  ///
  /// The two sides of a connection want opposite answers:
  ///
  /// - A SERVER (true, the default). dart:io buffers a whole WebSocket message
  ///   before delivering it, so the peak is resident before this class sees a
  ///   byte and cannot be avoided. Closing is then the only lever left — a
  ///   connection that survives lets one peer repeat that peak at will.
  /// - A CLIENT (false). The peer is the server it chose, and killing the
  ///   connection over one large response takes every other in-flight call with
  ///   it. gRPC's answer is RESOURCE_EXHAUSTED on that RPC, which is what this
  ///   produces.
  final bool closeOnOversizedFrame;

  /// Creates a multiplexed channel that encodes/decodes frames over [channel].
  ///
  /// [policy] bounds the RECEIVE path: a declared frame payload larger than
  /// [_maxFramePayloadBytes] is rejected from the header without buffering, and
  /// the reassembly buffer is capped at [_maxBufferedFrameBytes].
  RpcFrameMultiplexedChannel({
    required IRpcChannel channel,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    this.closeOnOversizedFrame = true,
  }) : _channel = channel,
       _policy = policy {
    _channelSub = _channel.incoming.listen(
      _onData,
      onError: (Object e) {
        if (!_incomingCtl.isClosed) _incomingCtl.addError(e);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed) return;

    Uint8List frame;
    if (message.payload != null) {
      frame = RpcChannelFrame.encodeData(
        streamId: message.streamId,
        payload: message.payload!,
        endOfStream: message.isEndOfStream,
      );
    } else if (message.metadata != null) {
      frame = RpcChannelFrame.encodeMetadata(
        streamId: message.streamId,
        metadata: message.metadata!,
        endOfStream: message.isEndOfStream,
      );
    } else if (message.isEndOfStream) {
      frame = RpcChannelFrame.encodeEndOfStream(message.streamId);
    } else {
      return;
    }

    await _channel.send(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _channelSub?.cancel();
    _channelSub = null;
    _buf = Uint8List(0);
    _bufLen = 0;

    try {
      await _channel.close();
    } catch (_) {}

    if (!_incomingCtl.isClosed) {
      await _incomingCtl.close();
    }
  }

  // -- Internal ---------------------------------------------------------------

  /// Largest legal channel-frame payload, in bytes.
  ///
  /// A channel frame's payload is not the application message: it is the
  /// gRPC-FRAMED message, so it carries a [RpcConstants.messagePrefixSize]
  /// prefix that [RpcSecurityPolicy.maxMessageLengthBytes] does not count.
  /// Bound the frame payload by the policy value directly and the real ceiling
  /// becomes `maxMessageLengthBytes - 5`, rejecting a message at exactly the
  /// configured limit.
  int get _maxFramePayloadBytes =>
      _policy.maxMessageLengthBytes + RpcConstants.messagePrefixSize;

  /// Reassembly-buffer cap, in bytes.
  ///
  /// One maximal frame must fit, and a frame is [RpcChannelFrame.headerSize]
  /// bytes of header plus [_maxFramePayloadBytes] of payload. The policy's
  /// buffer budget describes gRPC reassembly and knows nothing of this
  /// channel's own header, so the header is added here rather than stolen from
  /// the message budget.
  int get _maxBufferedFrameBytes =>
      _policy.effectiveMaxBufferedBytes + RpcChannelFrame.headerSize;

  /// Grows [_buf] so it can hold at least [needed] bytes, copying the existing
  /// (not-yet-emitted) bytes. Capacity doubles, so total copy cost across a
  /// stream is O(n), not O(n^2).
  void _ensureCapacity(int needed) {
    if (needed <= _buf.length) return;
    var cap = _buf.isEmpty ? 64 : _buf.length;
    while (cap < needed) {
      cap *= 2;
    }
    final grown = Uint8List(cap);
    grown.setRange(0, _bufLen, _buf);
    _buf = grown;
  }

  void _appendToBuffer(Uint8List chunk) {
    _ensureCapacity(_bufLen + chunk.length);
    _buf.setRange(_bufLen, _bufLen + chunk.length, chunk);
    _bufLen += chunk.length;
  }

  /// Reads the 9-byte header at the front of `_buf ++ data` and reports the
  /// frame when its declared payload is one we will never accept.
  ///
  /// Logical offset 0 is always a frame start: every complete frame is consumed
  /// on the chunk it arrives in, so the buffer only ever holds an incomplete
  /// prefix.
  ({int streamId, int payloadLen})? _refusedFrameHeader(Uint8List data) {
    const headerSize = RpcChannelFrame.headerSize;
    if (closeOnOversizedFrame) return null;
    if (_bufLen + data.length < headerSize) return null;

    final header = Uint8List(headerSize);
    var i = 0;
    while (i < headerSize && i < _bufLen) {
      header[i] = _buf[i];
      i++;
    }
    var j = 0;
    while (i < headerSize) {
      header[i] = data[j];
      i++;
      j++;
    }

    final view = ByteData.sublistView(header);
    final payloadLen = view.getUint32(5);

    // A metadata frame is bounded by maxMetadataBytes, 256x tighter than the
    // data ceiling at the defaults (64 KiB against 16 MiB). Check only the data
    // ceiling and every metadata frame between the two is buffered and then
    // rejected inside decodeAll, which reaches _failChannel -- so refusing a big
    // RESPONSE works while big TRAILERS still kill the connection.
    final isMetadata = (view.getUint8(4) & RpcChannelFrame.flagMetadata) != 0;
    final ceiling = isMetadata
        ? (_policy.maxMetadataBytes < _maxFramePayloadBytes
              ? _policy.maxMetadataBytes
              : _maxFramePayloadBytes)
        : _maxFramePayloadBytes;

    // Only the size ceiling. A frame that fits the ceiling but not a buffer the
    // caller shrank below it is left to the overflow path, which is what used to
    // handle it.
    if (payloadLen <= ceiling) return null;
    return (streamId: view.getUint32(0), payloadLen: payloadLen);
  }

  /// Notified as skipped bytes ARRIVE, never for bytes merely announced.
  ///
  /// The receiver returns flow-control credit only for messages it DELIVERS, so
  /// a skipped frame otherwise shrinks the peer's window permanently and the
  /// connection wedges after enough refusals.
  ///
  /// Crediting the DECLARED length instead is worse than the wedge it fixes: a
  /// peer sending nothing but 9-byte headers gets its window topped up for free,
  /// which is the one thing flow control exists to stop.
  void Function(int streamId, int bytes)? onFrameDiscarded;

  /// Returns credit for [bytes] of a refused frame that have actually arrived.
  void _creditSkipped(int streamId, int bytes) {
    if (bytes <= 0) return;
    onFrameDiscarded?.call(streamId, bytes);
  }

  /// Fails the call that frame belonged to, in the peer's own protocol terms.
  ///
  /// gRPC answers a message it cannot accept with RESOURCE_EXHAUSTED on that
  /// RPC; this delivers exactly that to the stream, and everything else on the
  /// connection carries on.
  void _refuseFrame(int streamId, int payloadLen) {
    if (_incomingCtl.isClosed) return;
    _incomingCtl.add(
      RpcTransportMessage(
        metadata: RpcMetadata.forTrailer(
          RpcStatus.resourceExhausted,
          message:
              'Received message larger than max '
              '($payloadLen vs. $_maxFramePayloadBytes)',
          // Trimmed, because this trailer is emitted INBOUND: the transport
          // validates it like anything else the peer sent, and a metadata
          // violation is answered by closing the connection. Untrimmed, a
          // `maxHeaderValueBytes` shorter than this message turns "refuse the
          // call" back into "kill the connection" -- by the length of the
          // refusal's own diagnosis.
          maxMessageLength: _policy.maxHeaderValueBytes,
        ),
        isEndOfStream: true,
        streamId: streamId,
      ),
    );
  }

  /// Fails the call a frame with undecodable metadata belonged to.
  ///
  /// INTERNAL rather than RESOURCE_EXHAUSTED: nothing about this is a limit,
  /// the peer simply sent headers that will not parse. Same
  /// `maxHeaderValueBytes` cap as [_refuseFrame], and for the same reason --
  /// this trailer is emitted INBOUND and validated like peer traffic, so a
  /// message longer than the cap would turn the refusal back into a
  /// connection kill.
  /// How many undecodable metadata frames a connection may cost before it is
  /// treated as hostile rather than buggy.
  ///
  /// Skipping instead of aborting made each one CHEAP FOR THE SENDER -- nine
  /// bytes in, a whole synthesized trailer out. Measured on an iOS 18.6
  /// simulator, 200k of them in one 1.8 MB buffer, before this cap:
  ///
  ///     1.8 MB in  ->  1050 MiB of RSS and 81 s of CPU
  ///
  /// Before the skip existed the connection died on the FIRST one, so the
  /// attacker got nothing; the skip is still right for the realistic case of a
  /// peer with a bug, and 64 is far more than that case ever produces.
  static const int _maxMalformedMetadataFrames = 64;

  int _malformedMetadata = 0;
  bool _metadataFloodTripped = false;

  void _refuseMetadata(int streamId) {
    if (_incomingCtl.isClosed) return;
    if (++_malformedMetadata > _maxMalformedMetadataFrames) {
      // Checked here but ACTED ON after decodeAll returns: this runs inside the
      // decode loop, and tearing the channel down from under it would leave the
      // buffer half-consumed.
      _metadataFloodTripped = true;
      return;
    }
    _incomingCtl.add(
      RpcTransportMessage(
        metadata: RpcMetadata.forTrailer(
          RpcStatus.internal,
          message: 'Undecodable metadata frame',
          maxMessageLength: _policy.maxHeaderValueBytes,
        ),
        isEndOfStream: true,
        streamId: streamId,
      ),
    );
  }

  void _onData(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;

    var data = chunk;
    while (true) {
      if (_skipRemaining > 0) {
        final drop = _skipRemaining < data.length
            ? _skipRemaining
            : data.length;
        _skipRemaining -= drop;
        // Credited HERE, as the bytes land, not when the frame was announced.
        _creditSkipped(_skipStreamId, drop);
        if (drop == data.length) return;
        data = Uint8List.sublistView(data, drop);
      }

      final refused = _refusedFrameHeader(data);
      if (refused == null) break;

      final total = RpcChannelFrame.headerSize + refused.payloadLen;
      final have = _bufLen + data.length;
      final consumedFromData = total - _bufLen;
      // Payload bytes of this frame that are already in hand. The 9-byte header
      // is ours, not the peer's charge: a sender bills itself for the frame
      // PAYLOAD only.
      final payloadHere =
          (have < total ? have : total) - RpcChannelFrame.headerSize;
      _buf = Uint8List(0);
      _bufLen = 0;
      _refuseFrame(refused.streamId, refused.payloadLen);
      _creditSkipped(refused.streamId, payloadHere);

      if (have < total) {
        _skipRemaining = total - have;
        _skipStreamId = refused.streamId;
        return;
      }
      if (consumedFromData >= data.length) return;
      data = Uint8List.sublistView(data, consumedFromData);
    }

    // Receive-path cap: never let the reassembly buffer grow past the policy
    // limit. A peer dribbling bytes toward a huge declared frame is stopped here
    // before the per-frame length check fires.
    //
    // Checked BEFORE the append, which is the whole point. Append first and the
    // oversized chunk is allocated and copied in full before the limit that
    // exists to prevent that is consulted, so the cap bounds what is RETAINED
    // and not what is ALLOCATED. Chunk size is entirely peer-controlled on the
    // transport this matters most for -- dart:io's WebSocket has no
    // message-size limit and delivers one message as ONE chunk -- so an
    // unauthenticated peer could make a server allocate an arbitrary multiple of
    // its own ceiling, once per message, before being disconnected for it.
    final incoming = _bufLen + data.length;
    if (incoming > _maxBufferedFrameBytes) {
      _failChannel(
        RpcFrameException(
          'Incoming frame buffer overflow: $incoming bytes '
          '(max: $_maxBufferedFrameBytes)',
        ),
      );
      return;
    }

    _appendToBuffer(data);

    // Decode against a view of the valid region. decodeAll is O(1) when no
    // frame is complete (it reads the 9-byte header and bails), so calling it
    // on every chunk is cheap; the cost that used to be quadratic was the
    // per-chunk buffer reallocation, now amortized O(1) via _appendToBuffer.
    final buffered = Uint8List.sublistView(_buf, 0, _bufLen);
    final List<RpcDecodedFrame> frames;
    final int consumed;
    try {
      (frames, consumed) = RpcChannelFrame.decodeAll(
        buffered,
        maxPayloadLen: _maxFramePayloadBytes,
        maxMetadataLen: _policy.maxMetadataBytes,
        // Same split as closeOnOversizedFrame, for the same reason: a peer we
        // must keep talking to gets the offending CALL failed, a peer we do not
        // gets the connection closed. Without it, one 9-byte empty metadata
        // frame takes every in-flight call on the connection with it.
        onMalformedMetadata: closeOnOversizedFrame ? null : _refuseMetadata,
      );
    } on RpcFrameException catch (error) {
      // What still reaches here is a SIZE violation, or malformed metadata on
      // a connection we have decided to close for. The framing is not
      // trustworthy past that point, so tearing down is the only safe answer.
      _failChannel(error);
      return;
    }

    if (_metadataFloodTripped) {
      // A peer past the cap is not a peer with a bug. Fail here, once decodeAll
      // has finished with the buffer.
      _failChannel(
        RpcFrameException(
          'Too many undecodable metadata frames '
          '(over $_maxMalformedMetadataFrames on this connection)',
        ),
      );
      return;
    }

    if (consumed > 0) {
      // Compact the unconsumed tail into a FRESH buffer. The decoded data
      // frames' payloads are sublistViews into the current `_buf`; copying the
      // tail out and rebinding `_buf` leaves the old buffer untouched, so those
      // emitted views stay valid even after we move on.
      if (consumed >= _bufLen) {
        _buf = Uint8List(0);
        _bufLen = 0;
      } else {
        final tailLen = _bufLen - consumed;
        final tail = Uint8List(tailLen);
        tail.setRange(0, tailLen, _buf, consumed);
        _buf = tail;
        _bufLen = tailLen;
      }
    }

    for (final frame in frames) {
      final message = RpcTransportMessage(
        payload: frame.payload,
        metadata: frame.metadata,
        isEndOfStream: frame.endOfStream,
        methodPath: frame.methodPath,
        streamId: frame.streamId,
      );
      if (!_incomingCtl.isClosed) _incomingCtl.add(message);
    }
  }

  /// Surfaces a typed receive-path error and closes the channel.
  ///
  /// Closes regardless of [RpcSecurityPolicy.closeOnProtocolError], unlike the
  /// per-message violations the transport layer reports. What reaches here is a
  /// framing error with no known next boundary -- a malformed metadata payload,
  /// or bytes that overflowed the buffer without a header explaining them --
  /// so there is nothing to resynchronise to and carrying on would decode the
  /// rest as garbage.
  ///
  /// An oversized DECLARED payload used to come here too, and that was wrong on
  /// its own terms: the header states the length, so the next boundary is known
  /// exactly. [_onData] now steps over such a frame and answers its stream with
  /// RESOURCE_EXHAUSTED. Measured against a server sending 2 MiB to a client
  /// capped at 256 KiB: the call failed AND every later call on the connection
  /// got "Transport is disconnected and has no socket", where http2 -- the same
  /// library, the same scenario -- failed only the call.
  void _failChannel(RpcFrameException error) {
    if (!_incomingCtl.isClosed) _incomingCtl.addError(error);
    // Drop any partially buffered bytes immediately; do not keep allocating.
    _buf = Uint8List(0);
    _bufLen = 0;

    // Tell the peer this was ITS fault, where the underlying protocol can say
    // so. A framing violation is deterministic -- the peer will send the same
    // malformed bytes again if it reads the failure as transient -- and closing
    // silently is exactly that invitation: a WebSocket peer sees 1005 "no status
    // received", indistinguishable from an ordinary server shutdown, which maps
    // to UNAVAILABLE and is retried.
    //
    // Channels with no close code on the wire fall through to the ordinary
    // close, so this changes nothing for them.
    unawaited(closeForProtocolError(error.message));
  }

  /// Forwarded so layers ABOVE this channel can report a peer fault too.
  ///
  /// The transport validates inbound metadata against the security policy, and
  /// that violation is as deterministic as a framing one. Hide the capability
  /// here and the transport can only reach `close()`, so a policy violation
  /// reads to the peer as retryable while a framing one does not.
  @override
  Future<void> closeForProtocolError(String reason) async {
    final channel = _channel;
    if (channel is! IRpcChannelProtocolClose) {
      await close();
      return;
    }
    if (_closed) return;
    // Flagged BEFORE the await, so nothing can be sent or decoded in the gap
    // while the byte channel is closing.
    _closed = true;
    await (channel as IRpcChannelProtocolClose).closeForProtocolError(reason);
    await _channelSub?.cancel();
    _channelSub = null;
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
  }

  /// Creates a paired client/server frame channel over in-memory byte streams.
  static (RpcFrameMultiplexedChannel, RpcFrameMultiplexedChannel) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final c2s = StreamController<Uint8List>();
    final s2c = StreamController<Uint8List>();

    final clientChannel = _PairedByteChannel(output: c2s, input: s2c.stream);
    final serverChannel = _PairedByteChannel(output: s2c, input: c2s.stream);

    return (
      RpcFrameMultiplexedChannel(channel: clientChannel, policy: policy),
      RpcFrameMultiplexedChannel(channel: serverChannel, policy: policy),
    );
  }
}

/// Simple paired in-memory byte channel for [RpcFrameMultiplexedChannel.pair].
class _PairedByteChannel implements IRpcChannel {
  final StreamController<Uint8List> _output;
  final StreamController<Uint8List> _inCtl = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;
  bool _closed = false;

  _PairedByteChannel({
    required StreamController<Uint8List> output,
    required Stream<Uint8List> input,
  }) : _output = output {
    _sub = input.listen(
      (data) {
        if (!_inCtl.isClosed) _inCtl.add(data);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _inCtl.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed || _output.isClosed) return;
    _output.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    if (!_output.isClosed) await _output.close();
    if (!_inCtl.isClosed) await _inCtl.close();
  }
}
