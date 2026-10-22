// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer endpoint runs one interceptor list for the calls it makes and the
// calls it serves. RpcCallInfo.direction tells the two apart, so an interceptor
// that belongs to one side -- auth injected on outgoing, checked on incoming --
// does not have to guess from incidental signals.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Record extends IRpcInterceptor {
  final seen = <RpcCallDirection>[];

  @override
  void check(RpcCallInfo call) => seen.add(call.direction);
}

Future<void> _echo(RpcPeerEndpoint from) => from.unary<RpcString, RpcString>(
  serviceName: 'S',
  methodName: 'echo',
  request: 'x'.rpc,
  requestCodec: _codec,
  responseCodec: _codec,
);

void main() {
  test('a peer interceptor sees outgoing, then incoming', () async {
    final (ta, tb) = RpcChannelTransport.pair();
    final a = RpcPeerEndpoint(transport: ta)..registerServiceContract(_Svc());
    final b = RpcPeerEndpoint(transport: tb)..registerServiceContract(_Svc());
    final record = _Record();
    a.addInterceptor(record);
    a.start();
    b.start();
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    await _echo(a);
    await _echo(b);

    expect(record.seen, [RpcCallDirection.outgoing, RpcCallDirection.incoming]);
  });
}
