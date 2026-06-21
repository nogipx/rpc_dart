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
class RpcFrameMultiplexedChannel implements IRpcMultiplexedChannel {
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

  /// Creates a multiplexed channel that encodes/decodes frames over [channel].
  ///
  /// [policy] bounds the RECEIVE path: a declared frame payload larger than
  /// [RpcSecurityPolicy.maxMessageLengthBytes] is rejected from the header
  /// without buffering, and the reassembly buffer is capped at
  /// [RpcSecurityPolicy.effectiveMaxBufferedBytes].
  RpcFrameMultiplexedChannel({
    required IRpcChannel channel,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
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

  void _onData(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;

    _appendToBuffer(chunk);

    // Receive-path cap: never let the reassembly buffer grow past the policy
    // limit. A peer dribbling bytes toward a huge declared frame is stopped
    // here even before the per-frame length check fires.
    if (_bufLen > _policy.effectiveMaxBufferedBytes) {
      final buffered = _bufLen;
      _failChannel(
        RpcFrameException(
          'Incoming frame buffer overflow: $buffered bytes '
          '(max: ${_policy.effectiveMaxBufferedBytes})',
        ),
      );
      return;
    }

    // Decode against a view of the valid region. decodeAll is O(1) when no
    // frame is complete (it reads the 9-byte header and bails), so calling it
    // on every chunk is cheap; the cost that used to be quadratic was the
    // per-chunk buffer reallocation, now amortized O(1) via _appendToBuffer.
    final data = Uint8List.sublistView(_buf, 0, _bufLen);
    final List<RpcDecodedFrame> frames;
    final int consumed;
    try {
      (frames, consumed) = RpcChannelFrame.decodeAll(
        data,
        maxPayloadLen: _policy.maxMessageLengthBytes,
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
  void _failChannel(RpcFrameException error) {
    if (!_incomingCtl.isClosed) _incomingCtl.addError(error);
    // Drop any partially buffered bytes immediately; do not keep allocating.
    _buf = Uint8List(0);
    _bufLen = 0;
    unawaited(close());
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
