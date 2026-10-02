// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request the caller cannot send -- its codec throws on message three --
// fails the call on the caller. The server must not see the two requests
// before it as the whole stream: a client-stream handler would commit them and
// answer OK. It sees the call abandoned instead, as when the caller's own
// request stream throws.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _RefusesBad implements IRpcCodec<RpcString> {
  @override
  Uint8List serialize(RpcString message) {
    if (message.value == 'bad') throw StateError('cannot serialize "bad"');
    return _codec.serialize(message);
  }

  @override
  RpcString deserialize(Uint8List bytes) => _codec.deserialize(bytes);
}

final class _Svc extends RpcResponderContract {
  _Svc(this.ends) : super('Svc');

  /// How each handler's request stream ended: `clean [..]` or `error [..]`.
  final List<String> ends;

  Future<void> _read(Stream<RpcString> requests, List<String> got) async {
    try {
      await for (final r in requests) {
        got.add(r.value);
      }
      ends.add('clean $got');
    } catch (_) {
      ends.add('error $got');
      rethrow;
    }
  }

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (requests, {RpcContext? context}) async {
        final got = <String>[];
        await _read(requests, got);
        return 'committed $got'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'b',
      handler: (requests, {RpcContext? context}) async* {
        await _read(requests, <String>[]);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Stream<RpcString> _requests() async* {
  for (final v in ['a', 'b', 'bad', 'c']) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    yield v.rpc;
  }
}

Future<List<String>> _serverEnds(
  IRpcCodec<RpcString> requestCodec, {
  required bool bidi,
}) async {
  final ends = <String>[];
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(ends))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final Future<Object?> call = bidi
      ? caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'b',
              requests: _requests(),
              requestCodec: requestCodec,
              responseCodec: _codec,
            )
            .toList()
      : caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'c',
          requestCodec: requestCodec,
          responseCodec: _codec,
        )(_requests());
  await call.then((_) {}, onError: (Object _) {});
  for (var i = 0; i < 50 && ends.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return ends;
}

void main() {
  for (final bidi in [false, true]) {
    final shape = bidi ? 'bidi' : 'client-stream';

    test(
      '$shape: the server does not take a cut-off stream as whole',
      () async {
        expect(await _serverEnds(_RefusesBad(), bidi: bidi), ['error [a, b]']);
      },
    );

    test(
      '$shape CONTROL: with a working codec the stream ends clean',
      () async {
        expect(await _serverEnds(_codec, bidi: bidi), ['clean [a, b, bad, c]']);
      },
    );
  }
}
