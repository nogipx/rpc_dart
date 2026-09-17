// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 373 proved its fix on RpcChannelTransport.pair() with a plain
// caller/responder pair, and that is one wiring out of several. These are the
// others, and the ablation says the defect was real in each: with the
// metadata-frame dispatch removed, every `silent` arm below goes to 0 and hangs
// while every `control` arm still reports 3.
//
//   wiring              silent (ablated)   silent (fixed)   control
//   peer endpoint            0 HANG            3 DONE        3 DONE
//   zero-copy                0 HANG            3 DONE        3 DONE
//   8 concurrent          0 of 8             8 of 8          n/a
//
// `control` is the same handler driven with a request stream that CLOSES at
// once — the case that worked before round 373 and must keep working.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A request stream that never produces and never closes: a subscription.
Stream<RpcString> _never() => StreamController<RpcString>().stream;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'push',
      handler: (reqs, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield 'p$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Zero-copy: no codecs, so it needs a transport that supports direct objects.
final class _ZeroCopyContract extends RpcResponderContract {
  _ZeroCopyContract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'pushZc',
      handler: (reqs, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield 'z$i'.rpc;
        }
      },
    );
  }
}

Future<List<String>> _collect(Stream<RpcString> responses) async {
  final got = <String>[];
  await for (final r in responses) {
    got.add(r.value);
  }
  return got;
}

void main() {
  test('WITNESS: a peer-endpoint subscription reaches the server', () async {
    // The peer endpoint filters incoming messages by stream-id parity, so it is
    // a different route into the same dispatch.
    final (a, b) = RpcChannelTransport.pair();
    final left = RpcPeerEndpoint(transport: a);
    final right = RpcPeerEndpoint(transport: b);
    right.registerServiceContract(_Contract());
    left.start();
    right.start();

    final got =
        await _collect(
          left.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'push',
            requests: _never(),
            requestCodec: _codec,
            responseCodec: _codec,
          ),
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('a silent bidi caller never reached the peer endpoint'),
        );
    expect(got, ['p0', 'p1', 'p2']);

    await left.close().catchError((_) {});
    await right.close().catchError((_) {});
    await a.close();
    await b.close();
  });

  test('WITNESS: a zero-copy subscription reaches the server', () async {
    // The other branch of _ensureBidirectionalResponder.
    final (client, server) = RpcInMemoryTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_ZeroCopyContract());
    responder.start();

    final got =
        await _collect(
          caller.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'pushZc',
            requests: _never(),
          ),
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('a silent zero-copy bidi caller never reached the server'),
        );
    expect(got, ['z0', 'z1', 'z2']);

    await caller.close().catchError((_) {});
    await responder.close().catchError((_) {});
    await client.close();
    await server.close();
  });

  test('WITNESS: eight concurrent subscriptions all reach the server', () async {
    // One connection, eight calls in flight at once: the dispatch is driven off
    // a shared pipeline and a shared stream-id space.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    final results =
        await Future.wait([
          for (var i = 0; i < 8; i++)
            _collect(
              caller.bidirectionalStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'push',
                requests: _never(),
                requestCodec: _codec,
                responseCodec: _codec,
              ),
            ),
        ]).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('at least one of eight concurrent calls hung'),
        );

    expect(results, everyElement(['p0', 'p1', 'p2']));

    await caller.close().catchError((_) {});
    await responder.close().catchError((_) {});
    await client.close();
    await server.close();
  });

  test('GUARD: a request stream that closes at once still works', () async {
    // The neighbouring case on every wiring above; it worked before round 373
    // and is what tells these witnesses apart from a blanket failure.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    final got = await _collect(
      caller.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'push',
        requests: const Stream<RpcString>.empty(),
        requestCodec: _codec,
        responseCodec: _codec,
      ),
    );
    expect(got, ['p0', 'p1', 'p2']);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
