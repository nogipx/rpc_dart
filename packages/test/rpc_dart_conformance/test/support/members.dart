// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The members of the matrix: one per transport. Each builds a real server and
// real clients through the transport's public API, the way its README and its
// own tests do, and puts the requested peer behaviour between them.
//
// Every row iterates [members], and every test name carries the member's
// name, so a member nobody wired into a row shows up as skipped, never as
// absent.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'calls.dart';
import 'contract.dart';
import 'isolate_worker.dart';
import 'peer.dart';
import 'pipe.dart';
import 'tcp_peer.dart';

/// Every member, in matrix order.
final List<Member> members = [
  ChannelMember(),
  HttpMember(),
  Http2Member(),
  WebSocketMember(),
  IsolateMember(),
  WasmMember(),
];

/// Members that carry calls over a TCP socket.
List<NetworkMember> get networkMembers =>
    members.whereType<NetworkMember>().toList();

/// One transport.
abstract base class Member {
  String get name;

  /// Why this member cannot run at all here, or null.
  String? get skip => null;

  /// Why this member cannot produce [behaviour], or null when it can.
  String? cannotProduce(PeerBehaviour behaviour) => null;

  /// Starts a server, with [behaviour] between it and every client dialled
  /// through the returned rig.
  Future<Rig> serve({
    PeerBehaviour behaviour = PeerBehaviour.normal,
    RpcSecurityPolicy serverPolicy = const RpcSecurityPolicy(),
  });

  @override
  String toString() => name;
}

/// A running server and the clients dialled to it.
abstract base class Rig {
  Rig({required this.behaviour, required this.serverPolicy});

  final PeerBehaviour behaviour;
  final RpcSecurityPolicy serverPolicy;

  /// Events reported by every handler of this server.
  final Probe probe = Probe();

  final List<RpcCallerEndpoint> _callers = [];

  /// A caller endpoint over a NEW connection to the server.
  Future<RpcCallerEndpoint> dial({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    final caller = RpcCallerEndpoint(transport: await connect(policy));
    _callers.add(caller);
    return caller;
  }

  /// A typed caller over a new connection.
  Future<ConformanceCaller> caller({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async => ConformanceCaller(await dial(policy: policy));

  /// A client transport over a new connection.
  Future<IRpcTransport> connect(RpcSecurityPolicy policy);

  /// Gauges of every server-side endpoint, summed: the endpoint's integer
  /// metrics, and its transport's health details as `transport.<key>`.
  Future<Map<String, int>> serverMetrics();

  /// The server side of every connection dies.
  Future<void> killPeer();

  /// Teardown. Bounded rather than asserted: a close that hangs is measured
  /// by the I-5 row that closes after each peer behaviour, and failing every
  /// other row's teardown on it would hide what those rows measured.
  Future<void> close() async {
    await _bounded(
      Future.wait([for (final c in _callers) c.close()]),
      '$runtimeType caller close',
    );
    await closeServer();
  }

  Future<void> closeServer();
}

/// Waits briefly for teardown [f]. An http2 close spends up to its 2 s
/// graceful budget by design, and a hanging one is asserted by I-5; a row
/// does not pay for either. What finishes later finishes in the background.
Future<void> _bounded(Future<Object?> f, String what) => f
    .then<void>((_) {}, onError: (Object _) {})
    .timeout(
      const Duration(milliseconds: 300),
      onTimeout: () => printOnFailure('teardown: $what still running'),
    );

/// Integer gauges of [endpoint] and its transport.
Future<Map<String, int>> endpointGauges(RpcEndpointBase endpoint) async {
  final out = <String, int>{};
  for (final e in endpoint.collectEndpointMetrics().entries) {
    if (e.value is int) out[e.key] = e.value! as int;
  }
  out.addAll(await transportGauges(endpoint.transport));
  return out;
}

/// Integer health details of [transport] as `transport.<key>`, and for a
/// channel transport the per-stream flow-control state as `fc.<key>`.
Future<Map<String, int>> transportGauges(IRpcTransport transport) async {
  final out = <String, int>{};
  final health = await transport.health();
  for (final e in health.details.entries) {
    if (e.value is int) out['transport.${e.key}'] = e.value! as int;
  }
  if (transport is RpcChannelTransport) {
    for (final e in transport.flowControlStateSizes.entries) {
      out['fc.${e.key}'] = e.value;
    }
  }
  return out;
}

Future<Map<String, int>> _sum(Iterable<RpcEndpointBase> endpoints) async {
  final out = <String, int>{};
  for (final e in endpoints) {
    for (final g in (await endpointGauges(e)).entries) {
      out[g.key] = (out[g.key] ?? 0) + g.value;
    }
  }
  return out;
}

// ---------------------------------------------------------------- channel --

/// The core's channel transport: `RpcChannelTransport.fromChannel` over an
/// in-memory byte pipe, the same shape as `RpcChannelTransport.pair()`.
final class ChannelMember extends Member {
  @override
  String get name => 'channel';

  @override
  Future<ChannelRig> serve({
    PeerBehaviour behaviour = PeerBehaviour.normal,
    RpcSecurityPolicy serverPolicy = const RpcSecurityPolicy(),
  }) async => ChannelRig(behaviour: behaviour, serverPolicy: serverPolicy);
}

final class ChannelRig extends Rig {
  ChannelRig({required super.behaviour, required super.serverPolicy});

  final List<Pipe> pipes = [];
  final List<RpcResponderEndpoint> endpoints = [];

  /// While false, a dial fails as a refused connection would.
  bool accepting = true;

  @override
  Future<IRpcTransport> connect(RpcSecurityPolicy policy) async {
    if (!accepting) {
      throw const SocketException('channel server is down');
    }
    final pipe = Pipe(behaviour: behaviour);
    pipes.add(pipe);
    if (behaviour != PeerBehaviour.silent) attachServer(pipe.server);
    return RpcChannelTransport.fromChannel(
      channel: pipe.client,
      isClient: true,
      policy: policy,
    );
  }

  /// Serves the conformance contract on [channel].
  RpcResponderEndpoint attachServer(IRpcChannel channel) {
    final endpoint =
        RpcResponderEndpoint(
            transport: RpcChannelTransport.fromChannel(
              channel: channel,
              isClient: false,
              policy: serverPolicy,
            ),
          )
          ..registerServiceContract(ConformanceResponder(probe.emit))
          ..start();
    endpoints.add(endpoint);
    return endpoint;
  }

  /// A raw end whose far side is a fresh server: bytes written to it reach
  /// the server's frame decoder untouched.
  PipeEnd rawToServer() {
    final pipe = Pipe();
    pipes.add(pipe);
    attachServer(pipe.server);
    return pipe.client;
  }

  @override
  Future<Map<String, int>> serverMetrics() => _sum(endpoints);

  @override
  Future<void> killPeer() async {
    for (final p in pipes) {
      p.kill();
    }
  }

  /// The server goes away: every connection drops, and dials fail until
  /// [startServer].
  Future<void> stopServer() async {
    accepting = false;
    await killPeer();
  }

  void startServer() => accepting = true;

  @override
  Future<void> closeServer() async {
    await _bounded(
      Future.wait([for (final e in endpoints) e.close()]),
      'channel server endpoint close',
    );
  }
}

// ---------------------------------------------------------------- network --

/// A member whose calls travel over TCP. A proxy carrying the rig's peer
/// behaviour sits between every client and the server.
abstract base class NetworkMember extends Member {
  @override
  Future<NetworkRig> serve({
    PeerBehaviour behaviour = PeerBehaviour.normal,
    RpcSecurityPolicy serverPolicy = const RpcSecurityPolicy(),
  }) async {
    final rig = newRig(behaviour, serverPolicy);
    final port = await rig.startServer();
    rig._proxy = await TcpProxy.start(upstreamPort: port, behaviour: behaviour);
    return rig;
  }

  NetworkRig newRig(PeerBehaviour behaviour, RpcSecurityPolicy serverPolicy);

  /// A client transport to `127.0.0.1:[port]`. With [lazy], a transport whose
  /// handshake may still be in progress (where the transport offers one), so
  /// a peer that never answers it cannot hold the dial.
  Future<IRpcTransport> connectTo(
    int port,
    RpcSecurityPolicy policy, {
    bool lazy = false,
  });
}

abstract base class NetworkRig extends Rig {
  NetworkRig(
    this.member, {
    required super.behaviour,
    required super.serverPolicy,
  });

  final NetworkMember member;
  TcpProxy? _proxy;

  TcpProxy get proxy => _proxy!;

  /// The server's own port, for a raw peer that bypasses the proxy.
  int get serverPort;

  /// Binds the server and returns its port.
  Future<int> startServer();

  /// Stops the server; the proxy stays, and refuses until [restartServer].
  Future<void> stopServer();

  /// Starts a new server and points the proxy at it.
  Future<void> restartServer() async {
    proxy.upstreamPort = await startServer();
  }

  @override
  Future<IRpcTransport> connect(RpcSecurityPolicy policy) => member.connectTo(
    proxy.port,
    policy,
    lazy: behaviour == PeerBehaviour.silent,
  );

  /// Server endpoints created so far, closed ones included: a closed endpoint
  /// that still counts a stream is a leak too.
  final List<RpcEndpointBase> endpoints = [];

  void registerOn(RpcResponderEndpoint endpoint) {
    endpoint.registerServiceContract(ConformanceResponder(probe.emit));
    endpoints.add(endpoint);
  }

  @override
  Future<Map<String, int>> serverMetrics() => _sum(endpoints);

  @override
  Future<void> killPeer() async => proxy.killAll();

  @override
  Future<void> closeServer() async {
    await _bounded(stopServer(), '$member server stop');
    await proxy.close();
  }
}

// ------------------------------------------------------------------- http2 --

final class Http2Member extends NetworkMember {
  @override
  String get name => 'http2';

  @override
  NetworkRig newRig(PeerBehaviour behaviour, RpcSecurityPolicy serverPolicy) =>
      _Http2Rig(this, behaviour: behaviour, serverPolicy: serverPolicy);

  @override
  Future<IRpcTransport> connectTo(
    int port,
    RpcSecurityPolicy policy, {
    bool lazy = false,
  }) => RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
    policy: policy,
  );
}

final class _Http2Rig extends NetworkRig {
  _Http2Rig(
    super.member, {
    required super.behaviour,
    required super.serverPolicy,
  });

  RpcHttp2Server? _server;

  @override
  int get serverPort => _server!.port;

  @override
  Future<int> startServer() async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: serverPolicy,
      onEndpointCreated: registerOn,
    );
    await server.start();
    _server = server;
    return server.port;
  }

  @override
  Future<void> stopServer() async => _server?.stop();
}

// -------------------------------------------------------------------- http --

final class HttpMember extends NetworkMember {
  @override
  String get name => 'http';

  @override
  NetworkRig newRig(PeerBehaviour behaviour, RpcSecurityPolicy serverPolicy) =>
      _HttpRig(this, behaviour: behaviour, serverPolicy: serverPolicy);

  @override
  Future<IRpcTransport> connectTo(
    int port,
    RpcSecurityPolicy policy, {
    bool lazy = false,
  }) async =>
      RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:$port', policy: policy);
}

final class _HttpRig extends NetworkRig {
  _HttpRig(
    super.member, {
    required super.behaviour,
    required super.serverPolicy,
  });

  RpcHttpServer? _server;

  @override
  int get serverPort => _server!.actualPort!;

  @override
  Future<int> startServer() async {
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: serverPolicy,
      onEndpointCreated: registerOn,
    );
    await server.start();
    await server.afterModulesStart();
    _server = server;
    return server.actualPort!;
  }

  @override
  Future<void> stopServer() async => _server?.stop();
}

// --------------------------------------------------------------- websocket --

final class WebSocketMember extends NetworkMember {
  @override
  String get name => 'websocket';

  @override
  NetworkRig newRig(PeerBehaviour behaviour, RpcSecurityPolicy serverPolicy) =>
      _WebSocketRig(this, behaviour: behaviour, serverPolicy: serverPolicy);

  @override
  Future<IRpcTransport> connectTo(
    int port,
    RpcSecurityPolicy policy, {
    bool lazy = false,
  }) async {
    final uri = Uri.parse('ws://127.0.0.1:$port');
    if (lazy) {
      // The README's form for a channel built by the caller: the transport
      // may be handed a channel whose handshake has not answered yet.
      return RpcWebSocketCallerTransport(
        WebSocketChannel.connect(uri),
        policy: policy,
      );
    }
    return RpcWebSocketCallerTransport.connect(
      uri,
      policy: policy,
      connectTimeout: const Duration(seconds: 2),
    );
  }
}

final class _WebSocketRig extends NetworkRig {
  _WebSocketRig(
    super.member, {
    required super.behaviour,
    required super.serverPolicy,
  });

  HttpServer? _http;
  RpcWebSocketServer? _server;

  @override
  int get serverPort => _http!.port;

  @override
  Future<int> startServer() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      policy: serverPolicy,
      onEndpointCreated: registerOn,
    );
    await server.start();
    _http = http;
    _server = server;
    return http.port;
  }

  @override
  Future<void> stopServer() async {
    await _server?.dispose();
    await _http?.close(force: true);
  }
}

// ----------------------------------------------------------------- isolate --

/// `RpcIsolateTransport.spawn`: one worker isolate per connection.
///
/// spawn applies ONE policy to both sides. A rig's server policy, when it is
/// not the default, is the one used; otherwise the dialled policy is.
final class IsolateMember extends Member {
  @override
  String get name => 'isolate';

  @override
  String? cannotProduce(PeerBehaviour behaviour) => switch (behaviour) {
    PeerBehaviour.slow =>
      'the isolate channel is private to rpc_dart_isolate: no public hook '
          'can delay its messages',
    PeerBehaviour.halfClose =>
      'a SendPort has no half-close: the worker is reachable or it is gone',
    _ => null,
  };

  @override
  Future<IsolateRig> serve({
    PeerBehaviour behaviour = PeerBehaviour.normal,
    RpcSecurityPolicy serverPolicy = const RpcSecurityPolicy(),
    String? workerMode,
  }) async => IsolateRig(
    behaviour: behaviour,
    serverPolicy: serverPolicy,
    workerMode:
        workerMode ??
        switch (behaviour) {
          PeerBehaviour.silent => WorkerMode.silent,
          // Messages cross whole, so "mid-message" is the worker exiting
          // while the call is in flight.
          PeerBehaviour.closesMidMessage => WorkerMode.exitMidCall,
          _ => WorkerMode.serve,
        },
  );
}

final class IsolateRig extends Rig {
  IsolateRig({
    required super.behaviour,
    required super.serverPolicy,
    required this.workerMode,
  });

  final String workerMode;
  final List<_Worker> _workers = [];

  @override
  Future<IRpcTransport> connect(RpcSecurityPolicy policy) async =>
      (await spawn(policy)).transport;

  /// Spawns a worker and returns its host-side transport.
  Future<({IRpcReconnectableTransport transport, void Function() kill})> spawn(
    RpcSecurityPolicy policy,
  ) async {
    final events = ReceivePort();
    final control = Completer<SendPort>();
    events.listen((Object? message) {
      final m = message! as List<Object?>;
      if (m[0] == 'control') {
        control.complete(m[1]! as SendPort);
      } else {
        probe.emit(m[0]! as String, m[1]! as int, m[2]! as int);
      }
    });
    final record =
        await RpcIsolateTransport.spawn(
          entrypoint: conformanceWorker,
          customParams: {'events': events.sendPort, 'mode': workerMode},
          policy: _isDefault(serverPolicy) ? policy : serverPolicy,
          startupTimeout: const Duration(seconds: 5),
        ).catchError((Object e) {
          events.close();
          throw e;
        });
    _workers.add(
      _Worker(record.kill, events, await control.future.timeout(_controlWait)),
    );
    return record;
  }

  static const _controlWait = Duration(seconds: 5);

  @override
  Future<Map<String, int>> serverMetrics() async {
    final out = <String, int>{};
    for (final w in _workers.where((w) => !w.dead)) {
      final reply = ReceivePort();
      w.control.send(<Object>['metrics', reply.sendPort]);
      final m = await reply.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => <String, int>{},
      );
      reply.close();
      for (final e in (m as Map).cast<String, int>().entries) {
        out[e.key] = (out[e.key] ?? 0) + e.value;
      }
    }
    return out;
  }

  @override
  Future<void> killPeer() async {
    for (final w in _workers) {
      w.control.send(<Object>['die']);
      w.dead = true;
    }
  }

  @override
  Future<void> closeServer() async {
    for (final w in _workers) {
      w.kill();
      w.events.close();
    }
  }
}

final class _Worker {
  _Worker(this.kill, this.events, this.control);
  final void Function() kill;
  final ReceivePort events;
  final SendPort control;
  bool dead = false;
}

bool _isDefault(RpcSecurityPolicy p) =>
    p.toMap().toString() == const RpcSecurityPolicy().toMap().toString();

// -------------------------------------------------------------------- wasm --

/// Listed so that every row shows it, and skipped with its condition.
final class WasmMember extends Member {
  @override
  String get name => 'wasm';

  @override
  String get skip =>
      'Flutter package outside the workspace; covered by melos run test:wasm '
      'and test:wasm:device';

  @override
  Future<Rig> serve({
    PeerBehaviour behaviour = PeerBehaviour.normal,
    RpcSecurityPolicy serverPolicy = const RpcSecurityPolicy(),
  }) => throw UnsupportedError(skip);
}
