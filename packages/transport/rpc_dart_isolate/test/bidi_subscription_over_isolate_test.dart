// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidirectional SUBSCRIPTION over a real isolate: the caller opens the
// channel, listens, and sends nothing. The third real transport — its channel
// is SendPort/ReceivePort rather than a socket, and its metadata frame is an
// _IsolateMessage, so the open it performs is a different one again.
//
// Measured with the core dispatch ablated and restored:
//
//   silent (ablated)   0 HANG      control   3 DONE
//   silent (fixed)     3 DONE      control   3 DONE

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'push',
      handler: (requests, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield 'p$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Top-level, as an isolate entrypoint must be.
void worker(IRpcTransport transport, Map<String, dynamic> params) {
  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_Svc());
  responder.start();
}

/// Never produces and never closes: a subscription.
Stream<RpcString> _never() => StreamController<RpcString>().stream;

Future<List<String>> _drive(
  RpcCallerEndpoint caller,
  Stream<RpcString> requests,
) async {
  final got = <String>[];
  await for (final r in caller.bidirectionalStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'push',
    requests: requests,
    requestCodec: _codec,
    responseCodec: _codec,
  )) {
    got.add(r.value);
  }
  return got;
}

void main() {
  late ({IRpcTransport transport, void Function() kill}) spawned;
  late RpcCallerEndpoint caller;

  setUp(() async {
    spawned = await RpcIsolateTransport.spawn(entrypoint: worker);
    caller = RpcCallerEndpoint(transport: spawned.transport);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    spawned.kill();
  });

  test('WITNESS: a silent caller receives over a real isolate', () async {
    final got = await _drive(caller, _never()).timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          fail('a bidi subscription never reached the worker isolate'),
    );
    expect(got, ['p0', 'p1', 'p2']);
  });

  test('GUARD: a request stream that closes at once still works', () async {
    final got = await _drive(caller, const Stream<RpcString>.empty());
    expect(got, ['p0', 'p1', 'p2']);
  });
}
