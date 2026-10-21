// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Byte channels for tests that drive a frame channel from the wire side.
///
/// [RawPeerChannel] stands in for a peer the test writes by hand.
/// [TapPipe] connects two frame channels and lets the test watch or rewrite
/// what crosses. Both deal with [RpcChannelFrame.preface], so a test handles
/// frames only.
library;

import 'dart:async';

import 'package:rpc_dart/transport.dart';

/// Whether [data] is the [RpcChannelFrame.preface] a frame channel writes
/// before its first frame.
bool isChannelPreface(Uint8List data) {
  final preface = RpcChannelFrame.preface;
  if (data.length != preface.length) return false;
  for (var i = 0; i < preface.length; i++) {
    if (data[i] != preface[i]) return false;
  }
  return true;
}

/// The stream id in the header of [frame].
int frameStreamId(Uint8List frame) =>
    (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];

/// A byte channel whose inbound side the test writes by hand.
///
/// The peer's preface is queued at construction, so what the test feeds is
/// read as frames. What the frame channel above sends is recorded in [sent],
/// without its preface.
final class RawPeerChannel extends IRpcChannel {
  /// [sync] makes inbound delivery synchronous. [throwOnSendAfterClose] makes
  /// a send after [close] throw, as a real socket does. [onSend] sees every
  /// frame after it is recorded; a throw from it fails that send. [preface]
  /// replaces the peer's preface; empty sends none.
  RawPeerChannel({
    bool sync = false,
    this.throwOnSendAfterClose = false,
    this.onSend,
    List<int>? preface,
  }) : _in = StreamController<Uint8List>(sync: sync) {
    final first = preface ?? RpcChannelFrame.preface;
    if (first.isNotEmpty) _in.add(Uint8List.fromList(first));
  }

  final StreamController<Uint8List> _in;
  final _sentCtl = StreamController<Uint8List>.broadcast(sync: true);
  bool _closed = false;

  /// Whether a send after [close] throws [StateError].
  final bool throwOnSendAfterClose;

  /// Called with every frame sent, after it is recorded.
  final void Function(Uint8List frame)? onSend;

  /// Every frame sent through this channel, in order.
  final List<Uint8List> sent = [];

  /// The frames of [sent] as they are sent.
  Stream<Uint8List> get onSent => _sentCtl.stream;

  /// The stream id of every frame in [sent].
  List<int> get sentStreamIds => [for (final f in sent) frameStreamId(f)];

  /// [sent], decoded.
  List<RpcDecodedFrame> get sentFrames => [
    for (final f in sent) ...RpcChannelFrame.decodeAll(f).$1,
  ];

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed && throwOnSendAfterClose) throw StateError('closed');
    if (isChannelPreface(data)) return;
    sent.add(data);
    _sentCtl.add(data);
    onSend?.call(data);
  }

  /// Delivers [bytes] as one inbound chunk.
  void feed(List<int> bytes) {
    if (_closed || _in.isClosed) return;
    _in.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  /// Fails the inbound stream with [error].
  void fail(Object error) {
    if (!_closed && !_in.isClosed) _in.addError(error);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_in.isClosed) await _in.close();
  }
}

/// One end of an in-memory byte pipe between two frame channels.
///
/// Each frame one end sends is recorded in its [sent] and delivered to the
/// other end, through [transform] when set. The preface crosses untouched.
final class TapPipe extends IRpcChannel {
  TapPipe._();

  /// Two connected ends.
  static (TapPipe, TapPipe) pair() {
    final a = TapPipe._();
    final b = TapPipe._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  late final TapPipe _peer;
  final _in = StreamController<Uint8List>();

  /// Every frame this end sent, in order, the preface excluded.
  final List<Uint8List> sent = [];

  /// When true, frames this end sends are recorded and then dropped.
  bool dropEverything = false;

  /// Replaces delivery of a frame: call `deliver` with what the other end
  /// should receive, any number of times.
  void Function(Uint8List frame, void Function(Uint8List) deliver)? transform;

  /// [sent], decoded.
  List<RpcDecodedFrame> get sentFrames => [
    for (final f in sent) ...RpcChannelFrame.decodeAll(f).$1,
  ];

  @override
  bool get isClosed => _in.isClosed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  void _deliver(Uint8List data) {
    if (!_peer._in.isClosed) _peer._in.add(data);
  }

  @override
  Future<void> send(Uint8List data) async {
    if (isChannelPreface(data)) {
      _deliver(data);
      return;
    }
    sent.add(data);
    if (dropEverything) return;
    final t = transform;
    if (t == null) {
      _deliver(data);
    } else {
      t(data, _deliver);
    }
  }

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}
