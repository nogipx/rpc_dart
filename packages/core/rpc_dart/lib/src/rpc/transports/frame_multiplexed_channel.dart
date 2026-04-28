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
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast();
  StreamSubscription<Uint8List>? _channelSub;
  Uint8List _readBuffer = Uint8List(0);
  bool _closed = false;

  /// Creates a multiplexed channel that encodes/decodes frames over [channel].
  RpcFrameMultiplexedChannel({required IRpcChannel channel})
      : _channel = channel {
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
    _readBuffer = Uint8List(0);

    try {
      await _channel.close();
    } catch (_) {}

    if (!_incomingCtl.isClosed) {
      await _incomingCtl.close();
    }
  }

  // -- Internal ---------------------------------------------------------------

  void _onData(Uint8List chunk) {
    if (_readBuffer.isEmpty) {
      _readBuffer = chunk;
    } else {
      final combined = Uint8List(_readBuffer.length + chunk.length);
      combined.setRange(0, _readBuffer.length, _readBuffer);
      combined.setRange(_readBuffer.length, combined.length, chunk);
      _readBuffer = combined;
    }

    final (frames, consumed) = RpcChannelFrame.decodeAll(_readBuffer);
    if (consumed > 0) {
      _readBuffer = consumed == _readBuffer.length
          ? Uint8List(0)
          : Uint8List.sublistView(_readBuffer, consumed);
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

  /// Creates a paired client/server frame channel over in-memory byte streams.
  static (RpcFrameMultiplexedChannel, RpcFrameMultiplexedChannel) pair() {
    final c2s = StreamController<Uint8List>();
    final s2c = StreamController<Uint8List>();

    final clientChannel = _PairedByteChannel(output: c2s, input: s2c.stream);
    final serverChannel = _PairedByteChannel(output: s2c, input: c2s.stream);

    return (
      RpcFrameMultiplexedChannel(channel: clientChannel),
      RpcFrameMultiplexedChannel(channel: serverChannel),
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
