// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Raw sockets for the network members: a TCP proxy placed between a real
// client and a real server that applies a peer behaviour to the bytes, and a
// fake server that runs a script instead of a protocol.
//
// Both are production code for the duration of a test (tests item A1): every
// socket future is handled, every write is guarded against a closed side, and
// `close()` tears down whatever is left on the failure path too. An error
// escaping from here would read as the library crashing (I-4).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'peer.dart';

/// One accepted connection and its upstream.
final class ProxyLink {
  ProxyLink._(this.client, this.upstream);

  final Socket client;
  final Socket? upstream;

  /// Bytes seen in each direction, when the proxy records.
  final List<int> c2s = [];
  final List<int> s2c = [];

  var _s2cPassed = 0;
  var _cut = false;
  var _dead = false;
  final _writeClosed = <Socket>{};

  bool _canWrite(Socket s) => !_dead && !_writeClosed.contains(s);

  Future<void> _write(Socket to, Uint8List data) async {
    if (!_canWrite(to)) return;
    try {
      to.add(data);
      await to.flush();
    } catch (_) {
      destroy();
    }
  }

  Future<void> _finWrite(Socket s) async {
    if (!_canWrite(s)) return;
    _writeClosed.add(s);
    try {
      await s.close();
    } catch (_) {
      // The peer may already be gone; the FIN is best effort.
    }
  }

  /// Both sockets go away at once, like a process that died.
  void destroy() {
    if (_dead) return;
    _dead = true;
    client.destroy();
    upstream?.destroy();
  }
}

/// A TCP proxy that applies a [PeerBehaviour].
final class TcpProxy {
  TcpProxy._(this._server, this.behaviour, this.upstreamPort, this.record);

  /// Starts a proxy to `127.0.0.1:[upstreamPort]`. A [PeerBehaviour.silent]
  /// proxy never connects upstream at all.
  static Future<TcpProxy> start({
    required int upstreamPort,
    PeerBehaviour behaviour = PeerBehaviour.normal,
    bool record = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = TcpProxy._(server, behaviour, upstreamPort, record);
    server.listen(proxy._accept, onError: (Object _) {});
    return proxy;
  }

  final ServerSocket _server;
  final PeerBehaviour behaviour;
  final bool record;

  /// Where connections go. Changed by a test that restarts the server.
  int upstreamPort;

  final List<ProxyLink> links = [];
  final _silent = <Socket>[];
  var _closed = false;

  int get port => _server.port;

  Future<void> _accept(Socket client) async {
    _guard(client);
    if (_closed) {
      client.destroy();
      return;
    }
    if (behaviour == PeerBehaviour.silent) {
      _silent.add(client);
      client.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      return;
    }
    Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        upstreamPort,
      );
    } catch (_) {
      // Nothing listens upstream: the client sees the connection drop, as it
      // would see a refused one.
      client.destroy();
      return;
    }
    _guard(upstream);
    final link = ProxyLink._(client, upstream);
    links.add(link);
    if (_closed) {
      link.destroy();
      return;
    }
    _pump(link, client, upstream, fromClient: true);
    _pump(link, upstream, client, fromClient: false);
  }

  void _pump(
    ProxyLink link,
    Socket from,
    Socket to, {
    required bool fromClient,
  }) {
    late final StreamSubscription<Uint8List> sub;
    sub = from.listen(
      (data) {
        if (record) (fromClient ? link.c2s : link.s2c).addAll(data);
        final cutting =
            behaviour == PeerBehaviour.closesMidMessage ||
            behaviour == PeerBehaviour.halfClose;
        if (!fromClient && cutting) {
          _cutting(link, data);
          return;
        }
        // Backpressure: read the next chunk only once this one is written.
        sub.pause();
        final write = behaviour == PeerBehaviour.slow
            ? Future<void>.delayed(slowChunkDelay, () => link._write(to, data))
            : link._write(to, data);
        write.whenComplete(sub.resume).ignore();
      },
      onError: (Object _) => link.destroy(),
      onDone: () {
        // Pass a FIN on, unless this direction was already cut.
        if (fromClient || !link._cut) link._finWrite(to).ignore();
      },
      cancelOnError: true,
    );
  }

  void _cutting(ProxyLink link, Uint8List data) {
    if (link._cut) return;
    final room = cutAfterBytes - link._s2cPassed;
    if (data.length < room) {
      link._s2cPassed += data.length;
      link._write(link.client, data).ignore();
      return;
    }
    link._cut = true;
    final head = Uint8List.sublistView(data, 0, room);
    link._write(link.client, head).then((_) {
      if (behaviour == PeerBehaviour.closesMidMessage) {
        link.destroy();
      } else {
        // FIN towards the client; the client-to-server direction stays open.
        link._finWrite(link.client).ignore();
      }
    }).ignore();
  }

  /// Every connection through this proxy dies at once.
  void killAll() {
    for (final l in links) {
      l.destroy();
    }
    for (final s in _silent) {
      s.destroy();
    }
  }

  Future<void> close() async {
    _closed = true;
    killAll();
    await _server.close();
  }
}

/// A server that runs [script] on every accepted socket instead of speaking a
/// protocol.
final class FakeServer {
  FakeServer._(this._server);

  /// With [readsItself], [script] owns the socket's input; otherwise what the
  /// client sends is read and dropped.
  static Future<FakeServer> start(
    Future<void> Function(Socket socket) script, {
    bool readsItself = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeServer._(server);
    server.listen((socket) {
      _guard(socket);
      fake._sockets.add(socket);
      if (!readsItself) {
        socket.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      }
      script(socket).catchError((Object _) => socket.destroy()).ignore();
    }, onError: (Object _) {});
    return fake;
  }

  final ServerSocket _server;
  final _sockets = <Socket>[];

  int get port => _server.port;

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

/// Writes [bytes] to [socket], then closes it or, with [destroy], drops it.
Future<void> writeThenEnd(
  Socket socket,
  List<int> bytes, {
  bool destroy = false,
}) async {
  try {
    socket.add(bytes);
    await socket.flush();
    if (destroy) {
      socket.destroy();
    } else {
      await socket.close();
    }
  } catch (_) {
    socket.destroy();
  }
}

/// A socket's `done` completes with an error when the peer resets it, and an
/// unhandled one would be reported as an uncaught error of the test.
void _guard(Socket socket) {
  socket.done.catchError((Object _) => socket).ignore();
}
