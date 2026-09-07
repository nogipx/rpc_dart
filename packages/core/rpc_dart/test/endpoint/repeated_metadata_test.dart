// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// gRPC allows Custom-Metadata keys to REPEAT, and HTTP semantics (RFC 9110
// s5.3) make repeated field lines equivalent to one line carrying the values
// comma-separated.
//
// The responder built its context with a plain map assignment, so only the LAST
// value survived. Measured with grpcurl against an http2 server,
// `-H 'x-tag: first' -H 'x-tag: second'`:
//
//     before : handler saw  x-tag: second        <- 'first' gone
//     after  : handler saw  x-tag: first,second
//
// The two views of one call also disagreed: RpcMetadata keeps both headers and
// its getHeaderValue returns the FIRST, while the context returned the last.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  Map<String, String> seen = const {};
  int calls = 0;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        calls++;
        seen = context?.headers ?? const {};
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Drives one call whose opening metadata carries [extra], and returns what the
/// handler's context ended up with.
Future<Map<String, String>> _headersSeenBy(List<RpcHeader> extra) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  final svc = _Svc();
  responder.registerServiceContract(svc);
  responder.start();

  final base = RpcMetadata.forClientRequest('Svc', 'echo');
  final id = client.createStream();
  client.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await client.sendMetadata(
    id,
    // methodPath is a FIELD, not a header: rebuilding from `headers` alone
    // drops it and the responder never learns which method to dispatch, which
    // is how the first version of this file managed to call nothing at all.
    RpcMetadata([...base.headers, ...extra], methodPath: base.methodPath),
  );
  await client.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
    endStream: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final seen = svc.seen;
  final calls = svc.calls;
  await responder.close();
  await client.close();
  await server.close();
  // Without this the cases below would pass vacuously on an empty map if the
  // call never reached the handler at all -- which is exactly how the first
  // version of this file failed.
  expect(calls, 1, reason: 'the handler must actually have run');
  return seen;
}

void main() {
  test('a repeated key reaches the handler with both values', () async {
    final seen = await _headersSeenBy([
      RpcHeader('x-tag', 'first'),
      RpcHeader('x-tag', 'second'),
    ]);
    expect(seen['x-tag'], 'first,second');
  });

  test('order is preserved, first to last', () async {
    // Load-bearing: a set or a reversed join would still "keep both" while
    // handing the application the values in an order the peer did not send.
    final seen = await _headersSeenBy([
      RpcHeader('x-tag', 'a'),
      RpcHeader('x-tag', 'b'),
      RpcHeader('x-tag', 'c'),
    ]);
    expect(seen['x-tag'], 'a,b,c');
  });

  test('GUARD: a single value is untouched', () async {
    // No stray separator, which a naive join would add.
    final seen = await _headersSeenBy([RpcHeader('x-single', 'only')]);
    expect(seen['x-single'], 'only');
  });

  test('GUARD: transport-level headers are still filtered out', () async {
    // The join must not resurrect the headers this deliberately drops.
    final seen = await _headersSeenBy([
      RpcHeader('content-type', 'application/grpc'),
      RpcHeader('te', 'trailers'),
    ]);
    expect(seen.containsKey('content-type'), isFalse);
    expect(seen.containsKey('te'), isFalse);
  });
}
