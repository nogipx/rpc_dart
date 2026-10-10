// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-9 -- reconnect is honest.
//
// A reconnecting client is Online again after the server restarts, and is
// never Online before the peer has proven it speaks the protocol.
//
// Both rows drive `RpcClientConnection` from core with a factory that builds
// the member's client transport, which is the reconnect path every transport
// README points to. The first row is also the valid neighbour of the second:
// against a real server the same connection does go Online.
//
// "The server restarts" is, per member: the server stops and a new one starts
// behind the same address (network); every pipe drops and dials fail until
// the server is back (channel); the worker exits and the factory spawns the
// next one (isolate).

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/isolate_worker.dart';
import 'support/matrix.dart';
import 'support/pipe.dart';
import 'support/tcp_peer.dart';

/// Neither transport has a readiness signal (`IRpcTransportReadiness`), so
/// RpcClientConnection reports Online the moment the factory returns.
const _knownFailing = <String, String>{
  'channel | peer that never speaks the protocol':
      'states [Connecting, Online] against a byte pipe whose peer never '
      'sent a byte: RpcChannelTransport.fromChannel is Online on construction',
  'http | peer that never speaks the protocol':
      'states [Connecting, Online] against a server that accepts and never '
      'answers: RpcHttpCallerTransport is Online on construction',
};

const _backoff = ExponentialBackoff(
  baseDelay: Duration(milliseconds: 20),
  maxDelay: Duration(milliseconds: 100),
  jitter: false,
);

/// A connection over [factory] whose every state is recorded.
(RpcClientConnection, List<RpcClientConnectionState>) _connection(
  Future<IRpcReconnectableTransport> Function() factory,
) {
  final states = <RpcClientConnectionState>[];
  final connection = RpcClientConnection(
    transportFactory: factory,
    backoff: _backoff,
    connectTimeout: const Duration(milliseconds: 500),
    onStateChanged: states.add,
  );
  addTearDown(connection.dispose);
  return (connection, states);
}

Future<void> _reaches<T extends RpcClientConnectionState>(
  RpcClientConnection connection,
  String what,
) async {
  if (connection.currentState is T) return;
  await connection.state
      .firstWhere((s) => s is T)
      .timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          '$what: still ${connection.currentState.runtimeType} after 5 s',
        ),
      );
}

/// Calls until one succeeds, within 5 s.
Future<void> _eventuallyServes(RpcCallerEndpoint endpoint) async {
  final caller = ConformanceCaller(endpoint);
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final outcome = await Call.start(
      caller,
      CallShape.unary,
      Blob.request(id: nextCallId()),
      deadline: const Duration(seconds: 1),
    ).outcome;
    if (outcome.ok) return;
    if (DateTime.now().isAfter(until)) {
      fail('no call succeeded within 5 s of the restart; last: $outcome');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<IRpcReconnectableTransport> _reconnectable(
  Future<IRpcTransport> transport,
) async => (await transport) as IRpcReconnectableTransport;

void main() {
  group('I-9 Online again after the server restarts:', () {
    for (final member in members) {
      cell(member, 'server restart', knownFailing: _knownFailing, () async {
        final rig = await member.serve();
        addTearDown(rig.close);
        const policy = RpcSecurityPolicy();

        late final RpcClientConnection c;
        final Future<IRpcReconnectableTransport> Function() factory;
        final Future<void> Function() restart;
        switch (rig) {
          case NetworkRig():
            factory = () =>
                _reconnectable(rig.member.connectTo(rig.proxy.port, policy));
            // http has no connection to lose: nothing reports Offline there.
            final dropIsVisible = rig.member is! HttpMember;
            restart = () async {
              await rig.stopServer();
              rig.proxy.killAll();
              if (dropIsVisible) {
                await _reaches<RpcClientOffline>(c, 'server stopped');
              }
              await rig.restartServer();
            };
          case ChannelRig():
            factory = () => _reconnectable(rig.connect(policy));
            restart = () async {
              await rig.stopServer();
              await _reaches<RpcClientOffline>(c, 'server stopped');
              rig.startServer();
            };
          case IsolateRig():
            factory = () async => (await rig.spawn(policy)).transport;
            restart = () async {
              await rig.killPeer();
              await _reaches<RpcClientOffline>(c, 'worker exited');
            };
          default:
            throw UnsupportedError('$rig');
        }

        (c, _) = _connection(factory);
        final endpoint = RpcCallerEndpoint(transport: c.transport);
        addTearDown(endpoint.close);
        c.connect();
        await _reaches<RpcClientOnline>(c, 'first connect');
        await _eventuallyServes(endpoint);

        await restart();
        await _reaches<RpcClientOnline>(c, 'after the restart');
        await _eventuallyServes(endpoint);
      });
    }
  });

  group('I-9 never Online before the peer speaks:', () {
    for (final member in members) {
      cell(
        member,
        'peer that never speaks the protocol',
        knownFailing: _knownFailing,
        () async {
          const policy = RpcSecurityPolicy();
          final Future<IRpcReconnectableTransport> Function() factory;
          switch (member) {
            case NetworkMember():
              final silent = await TcpProxy.start(
                upstreamPort: 0,
                behaviour: PeerBehaviour.silent,
              );
              addTearDown(silent.close);
              factory = () =>
                  _reconnectable(member.connectTo(silent.port, policy));
            case ChannelMember():
              factory = () async => RpcChannelTransport.fromChannel(
                channel: Pipe(behaviour: PeerBehaviour.silent).client,
                isClient: true,
              );
            case IsolateMember():
              final rig = await member.serve(
                workerMode: WorkerMode.refuseToStart,
              );
              addTearDown(rig.close);
              factory = () async => (await rig.spawn(policy)).transport;
            default:
              throw UnsupportedError('$member');
          }

          final (connection, states) = _connection(factory);
          connection.connect();
          // Wait for three attempts to have been made -- each one judged
          // before the next starts -- or for Online, whichever comes first.
          // Three attempts against a peer that never spoke is the GUARD that
          // the absence of Online is not the absence of an attempt.
          await connection.state
              .firstWhere(
                (s) =>
                    s is RpcClientOnline ||
                    states.whereType<RpcClientConnecting>().length >= 3,
              )
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () => fail(
                  'fewer than three connect attempts in 5 s; states: '
                  '${states.map((s) => s.runtimeType).toList()}',
                ),
              );
          expect(
            states.whereType<RpcClientOnline>(),
            isEmpty,
            reason:
                'Online with a peer that never spoke; states: '
                '${states.map((s) => s.runtimeType).toList()}',
          );
        },
      );
    }
  });
}
