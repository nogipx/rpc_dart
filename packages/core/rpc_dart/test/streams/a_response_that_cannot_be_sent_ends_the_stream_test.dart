// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A streaming response the responder cannot serialize was skipped: the caller
// read the responses after it as the stream simply continuing, and learned of
// the failure only at the end, which an endless stream never reaches. Unary and
// client-stream answered INTERNAL at once.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Throws on serializing 'bad'.
final class _Refuses implements IRpcCodec<RpcString> {
  @override
  Uint8List serialize(RpcString message) {
    if (message.value == 'bad') throw StateError('cannot serialize');
    return _codec.serialize(message);
  }

  @override
  RpcString deserialize(Uint8List bytes) => _codec.deserialize(bytes);
}

var _produced = 0;

/// Endless; the second value cannot be serialized when [bad].
Stream<RpcString> _ticks(bool bad) async* {
  for (var i = 0; ; i++) {
    _produced++;
    yield (i == 1 && bad ? 'bad' : 'ok$i').rpc;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Svc extends RpcResponderContract {
  _Svc(this.bad) : super('Svc');
  final bool bad;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'items',
      handler: (r, {RpcContext? context}) => _ticks(bad),
      requestCodec: _codec,
      responseCodec: _Refuses(),
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      handler: (reqs, {RpcContext? context}) => _ticks(bad),
      requestCodec: _codec,
      responseCodec: _Refuses(),
    );
  }
}

/// What the caller reads (up to three events), and what the handler produced
/// in the 300 ms after.
Future<(List<String>, int)> _run(String shape, {required bool bad}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(bad))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  _produced = 0;
  final stream = shape == 'server'
      ? caller.serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'items',
          request: 'q'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
      : caller.bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'chat',
          requests: StreamController<RpcString>().stream,
          requestCodec: _codec,
          responseCodec: _codec,
        );
  final seen = <String>[];
  final done = Completer<void>();
  late StreamSubscription<RpcString> sub;
  sub = stream.listen(
    (r) {
      seen.add(r.value);
      if (seen.length == 3) {
        unawaited(sub.cancel());
        if (!done.isCompleted) done.complete();
      }
    },
    onError: (Object e) {
      seen.add('error ${e is RpcStatusException ? e.statusCode.code : e}');
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(const Duration(seconds: 3));
  final at = _produced;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return (seen, _produced - at);
}

void main() {
  for (final shape in ['server', 'bidi']) {
    test('WITNESS $shape: a response that cannot be serialized ends the '
        'stream there', () async {
      final (seen, _) = await _run(shape, bad: true);
      expect(seen, ['ok0', 'error ${RpcStatus.internal.code}']);
    });

    test('GUARD $shape: the handler stops producing behind it', () async {
      final (_, after) = await _run(shape, bad: true);
      expect(after, lessThanOrEqualTo(1));
    });

    test('GUARD $shape: every response serializes', () async {
      final (seen, _) = await _run(shape, bad: false);
      expect(seen, ['ok0', 'ok1', 'ok2']);
    });
  }
}
