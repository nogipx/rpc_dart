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
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast();
  StreamSubscription<Uint8List>? _channelSub;

  /// Growable reassembly buffer. Valid data is `_buf[0.._bufLen)`; capacity may
  /// exceed [_bufLen]. Appends grow capacity geometrically, so a peer dribbling
  /// one frame across many tiny chunks costs O(n) total instead of O(n^2)
  /// (the old code reallocated and recopied the whole buffer on every chunk).
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
  /// The two sides of a connection want opposite answers, and both were
  /// measured:
  ///
  /// - A SERVER (true, the default). dart:io buffers a whole WebSocket message
  ///   before delivering it, so the peak is resident before this class sees a
  ///   byte and cannot be avoided. Closing is then the only lever there is: a
  ///   connection that survives lets one peer repeat that peak as often as it
  ///   likes. See `oversized_message_is_refused_test` in rpc_dart_websocket.
  /// - A CLIENT (false). The peer here is the server it chose, and killing the
  ///   connection over one large response takes every other in-flight call with
  ///   it. Measured against a server sending 2 MiB to a client capped at 256
  ///   KiB: the call failed AND the next one got "Transport is disconnected and
  ///   has no socket", where http2 -- same library, same scenario -- failed only
  ///   the call. gRPC's answer is RESOURCE_EXHAUSTED on that RPC, which is what
  ///   this produces.
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
  /// gRPC-framed message, so it carries a [RpcConstants.messagePrefixSize]
  /// prefix that [RpcSecurityPolicy.maxMessageLengthBytes] — "max payload size
  /// of a single decoded gRPC message" — does not count. Bounding the frame
  /// payload by the policy value directly made the real ceiling
  /// `maxMessageLengthBytes - 5`, so a message at exactly the configured limit
  /// was rejected as oversized.
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
    // data ceiling at the defaults (64 KiB against 16 MiB). Checking only the
    // data ceiling left every metadata frame between the two to be buffered and
    // then rejected inside decodeAll, which reaches _failChannel -- so round
    // 161's fix worked for a big RESPONSE and not for big TRAILERS, measured
    // identically fatal on both sides.
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
  /// a skipped frame otherwise shrinks the peer's window for good. Measured with
  /// an 8 MiB connection window and 2 MiB refused per call: the connection
  /// wedged on the FOURTH refusal and every later call timed out at 6 s.
  /// Nothing before round 161 could hit this -- the connection used to die on
  /// the first oversized frame, so there was no "later".
  ///
  /// Crediting the DECLARED length instead was worse than the wedge it fixed: a
  /// peer sending nothing but 9-byte headers had its own window topped up for
  /// free, which is the one thing flow control exists to stop. Measured: 9 bytes
  /// delivered, 1 048 576 bytes granted back.
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
          // This trailer is emitted INBOUND, so RpcChannelTransport validates it
          // like anything else the peer sent -- and a metadata violation is
          // answered by closing the connection. Its own message is ~52
          // characters, so a smaller `maxHeaderValueBytes` turned "refuse this
          // call" back into "kill the connection", undoing round 161 by the
          // length of its own diagnosis. Measured over websocket, one oversized
          // response then a small call:
          //
          //   cap 8192 : status 8              next call ok
          //   cap   64 : RpcFrameException     next call StateError (dead)
          //   cap   32 : the same
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
    // limit. A peer dribbling bytes toward a huge declared frame is stopped
    // here even before the per-frame length check fires.
    //
    // Checked BEFORE the append, which is the whole point. Appending first
    // allocated the oversized chunk in full and copied it, and only then
    // consulted the limit that exists to prevent exactly that -- so the cap
    // bounded what was RETAINED and not what was ALLOCATED. Measured with a
    // 16 MiB policy limit, feeding one 256 MiB chunk:
    //
    //   allocated by the channel : 256.2 MiB   (16x the configured cap)
    //   after this check         : 0.0 MiB
    //
    // and the chunk size is entirely peer-controlled on the transport this
    // matters most for: dart:io's WebSocket has no message-size limit and
    // delivers one WS message as ONE chunk, measured at 96 MiB arriving whole.
    // So any unauthenticated peer could make a server allocate an arbitrary
    // multiple of its own configured ceiling, once per message, before being
    // disconnected for it.
    //
    // The reported byte count is unchanged: the old text printed `_bufLen`
    // after the append, which is this same sum.
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
      );
    } on RpcFrameException catch (error) {
      // A rejected frame (oversized declared payload or malformed metadata) is
      // a protocol violation: surface a typed, handled error and tear down the
      // channel rather than buffering or throwing into the receive loop's zone.
      _failChannel(error);
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
    // so. A framing violation is deterministic: the peer sent something
    // malformed and will send it again if it believes the failure was
    // transient. Closing silently is exactly that invitation -- a WebSocket
    // peer then sees 1005 "no status received", which maps to UNAVAILABLE and
    // is retried. Measured against an rpc_dart server:
    //
    //   server shutdown           : 1005 -> UNAVAILABLE (retryable)  correct
    //   client protocol violation : 1005 -> UNAVAILABLE (retryable)  WRONG
    //
    // Channels without a close code on the wire fall through to the ordinary
    // close, so this changes nothing for them.
    unawaited(closeForProtocolError(error.message));
  }

  /// Forwarded so layers ABOVE this channel can report a peer fault too.
  ///
  /// The transport validates inbound metadata against the security policy, and
  /// that violation is as deterministic as a framing one — but it could only
  /// reach `close()`, because this wrapper hid the capability. Measured against
  /// a raw peer: a policy violation closed 1005 (UNAVAILABLE, retried) while a
  /// framing violation closed 4400 (UNKNOWN, not retried).
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
