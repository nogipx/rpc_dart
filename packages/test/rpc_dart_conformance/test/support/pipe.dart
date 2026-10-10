// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The channel member's link: an in-memory byte pipe between two IRpcChannel
// ends, shaped like the core's own paired byte channel, with the peer
// behaviours applied to the bytes in flight. Both ends are wrapped by
// `RpcChannelTransport.fromChannel`, so everything above the bytes is the
// library's own code.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'peer.dart';

/// Two connected byte channels.
final class Pipe {
  Pipe({this.behaviour = PeerBehaviour.normal, this.record = false});

  final PeerBehaviour behaviour;

  /// Whether to keep a copy of every byte, for replay.
  final bool record;

  late final PipeEnd client = PipeEnd._(this, isClient: true);
  late final PipeEnd server = PipeEnd._(this, isClient: false);

  /// Recorded client-to-server and server-to-client bytes.
  final List<int> c2s = [];
  final List<int> s2c = [];

  var _s2cPassed = 0;
  var _cut = false;
  Future<void> _c2sChain = Future<void>.value();
  Future<void> _s2cChain = Future<void>.value();

  void _route(bool fromClient, Uint8List data) {
    if (record) (fromClient ? c2s : s2c).addAll(data);
    final to = fromClient ? server : client;
    switch (behaviour) {
      case PeerBehaviour.normal:
        to._deliver(data);
      case PeerBehaviour.silent:
        // Nobody on the far side: client bytes vanish, nothing comes back.
        break;
      case PeerBehaviour.slow:
        if (fromClient) {
          _c2sChain = _c2sChain.then((_) => _later(to, data));
        } else {
          _s2cChain = _s2cChain.then((_) => _later(to, data));
        }
      case PeerBehaviour.closesMidMessage:
      case PeerBehaviour.halfClose:
        if (fromClient) {
          to._deliver(data);
          return;
        }
        if (_cut) return;
        final room = cutAfterBytes - _s2cPassed;
        if (data.length < room) {
          _s2cPassed += data.length;
          to._deliver(data);
          return;
        }
        _cut = true;
        to._deliver(Uint8List.sublistView(data, 0, room));
        if (behaviour == PeerBehaviour.closesMidMessage) {
          kill();
        } else {
          // FIN towards the client only; the server keeps reading.
          client._endInput();
        }
    }
  }

  Future<void> _later(PipeEnd to, Uint8List data) =>
      Future<void>.delayed(slowChunkDelay, () => to._deliver(data));

  /// The link dies: both ends see the other go away.
  void kill() {
    client._endInput();
    server._endInput();
  }
}

/// One end of a [Pipe].
final class PipeEnd implements IRpcChannel {
  PipeEnd._(this._pipe, {required this.isClient});

  final Pipe _pipe;
  final bool isClient;
  final _in = StreamController<Uint8List>();
  bool _closed = false;

  PipeEnd get _peer => isClient ? _pipe.server : _pipe.client;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    // A copy: a sent chunk is handed over, and the sender may reuse its list.
    _pipe._route(isClient, Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _endInput();
    _peer._endInput();
  }

  void _deliver(Uint8List data) {
    if (!_in.isClosed) _in.add(data);
  }

  void _endInput() {
    if (!_in.isClosed) _in.close().ignore();
  }
}
