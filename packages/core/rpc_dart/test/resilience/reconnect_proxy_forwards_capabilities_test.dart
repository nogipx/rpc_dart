// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection.transport is a wrapper, and every optional transport
// capability is discovered by an `is` check that falls back SILENTLY. The proxy
// declared IRpcTransport and IRpcStreamReset alone, so an endpoint built on it
// lost all four of the others: the caller's parser fell back to
// `const RpcSecurityPolicy()` (a 20 MiB response refused under a configured
// 64 MiB), a codec-free call was refused outright, and the responder pipeline
// could not defer flow-control metering, crediting on arrival instead of on
// consumption.
//
// One test per capability, so a canary on any one of them fails alone.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _mib = 1024 * 1024;

/// Four times the 16 MiB `const RpcSecurityPolicy()` defaults to, so a 20 MiB
/// body tells "the configured policy" from "the default".
const _policy = RpcSecurityPolicy(maxMessageLengthBytes: 64 * _mib);
const _bodyBytes = 20 * _mib;

final _codec = RpcCodec(RpcString.fromJson);

/// Brings an [RpcClientConnection] online over [inner] and returns its proxy.
Future<IRpcTransport> _proxyOver(IRpcTransport inner) async {
  final conn = RpcClientConnection(transportFactory: () async => inner);
  addTearDown(conn.dispose);
  conn.connect();
  final online = Completer<void>();
  final sub = conn.state.listen((s) {
    if (s is RpcClientOnline && !online.isCompleted) online.complete();
  });
  if (conn.currentState is RpcClientOnline && !online.isCompleted) {
    online.complete();
  }
  await online.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  return conn.transport;
}

final class _BigContract extends RpcResponderContract {
  _BigContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Big',
      handler: (req, {RpcContext? context}) async => ('x' * _bodyBytes).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    // No codecs: a zero-copy registration.
    addUnaryMethod<Uint8List, Uint8List>(
      methodName: 'Echo',
      handler: (req, {RpcContext? context}) async => req,
    );
  }
}

final class _UploadContract extends RpcResponderContract {
  _UploadContract(this.started, this.gate) : super('Svc');

  final Completer<void> started;
  final Completer<void> gate;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        if (!started.isCompleted) started.complete();
        await gate.future;
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  group('RpcClientConnection.transport forwards transport capabilities', () {
    test('the caller parser is bound by the transport policy, not the '
        'defaults', () async {
      // The CHANNEL carries its own copy of the policy and bounds reassembly
      // with it; left at the default it refuses the body before the caller's
      // parser is consulted and the test says nothing about the proxy.
      final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
        policy: _policy,
      );
      final client = RpcChannelTransport(
        channel: clientCh,
        isClient: true,
        policy: _policy,
      );
      final server = RpcChannelTransport(
        channel: serverCh,
        isClient: false,
        policy: _policy,
      );
      addTearDown(client.close);
      addTearDown(server.close);

      final caller = RpcCallerEndpoint(transport: await _proxyOver(client));
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(caller.close);
      addTearDown(responder.close);
      responder.registerServiceContract(_BigContract());
      responder.start();

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Big',
            request: 'req'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 30));

      expect(
        reply.value.length,
        _bodyBytes,
        reason:
            'the proxy answered with const RpcSecurityPolicy(), so the '
            'parser enforced the 16 MiB default instead of the 64 MiB '
            'the transport was configured with',
      );
    });

    test('a zero-copy call is accepted over a zero-copy transport', () async {
      final (client, server) = RpcChannelTransport.memoryPair();
      addTearDown(client.close);
      addTearDown(server.close);

      final proxy = await _proxyOver(client);
      expect(
        proxy.supportsZeroCopy,
        isTrue,
        reason: 'the proxy hardcoded false over a transport that supports it',
      );

      final caller = RpcCallerEndpoint(transport: proxy);
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(caller.close);
      addTearDown(responder.close);
      responder.registerServiceContract(_EchoContract());
      responder.start();

      final reply = await caller
          .unaryRequest<Uint8List, Uint8List>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: Uint8List.fromList([1, 2, 3]),
          )
          .timeout(const Duration(seconds: 10));
      expect(reply, [1, 2, 3]);
    });

    test('the responder pipeline can defer flow-control metering', () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
        policy: _policy,
      );
      // The side under test is the client half, which is what the proxy
      // reports; the peer on the other side calls INTO it.
      final under = RpcChannelTransport(
        channel: clientCh,
        isClient: true,
        policy: _policy,
      );
      final other = RpcChannelTransport(
        channel: serverCh,
        isClient: false,
        policy: _policy,
      );
      addTearDown(under.close);
      addTearDown(other.close);

      final localPeer = RpcPeerEndpoint(transport: await _proxyOver(under));
      addTearDown(localPeer.close);
      localPeer.registerServiceContract(_UploadContract(started, gate));
      localPeer.start();
      final remotePeer = RpcPeerEndpoint(transport: other);
      addTearDown(remotePeer.close);
      remotePeer.start();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      final call = remotePeer.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Upload',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      unawaited(
        call(
          Stream<RpcString>.fromIterable(['a'.rpc, 'b'.rpc]),
        ).then((_) {}, onError: (Object _) {}),
      );

      await started.future.timeout(const Duration(seconds: 10));
      expect(
        under.flowControlStateSizes['deferred'],
        1,
        reason:
            'without IRpcFlowControlled on the proxy the pipeline credits on '
            'arrival, leaving the upload direction unbounded',
      );
    });

    test('the id cursor does not go backwards across a reconnect', () async {
      final first = RpcChannelTransport.memoryPair().$1;
      final second = RpcChannelTransport.memoryPair().$1;
      addTearDown(first.close);
      addTearDown(second.close);

      var built = 0;
      final conn = RpcClientConnection(
        transportFactory: () async => built++ == 0 ? first : second,
      );
      addTearDown(conn.dispose);
      conn.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final proxy = conn.transport;
      expect(
        proxy,
        isA<IRpcStreamIdSequence>(),
        reason: 'the proxy did not declare the capability at all',
      );

      // Mint a few ids on the first connection.
      for (var i = 0; i < 3; i++) {
        proxy.createStream();
      }
      final before = (proxy as IRpcStreamIdSequence).lastIssuedStreamId;
      expect(before, greaterThan(0));

      conn.forceReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        (proxy as IRpcStreamIdSequence).lastIssuedStreamId,
        greaterThanOrEqualTo(before),
        reason:
            'a fresh transport restarts its ids at 1, so a cursor read off '
            'the proxy must report the watermark it carried across',
      );
    });
  });
}
