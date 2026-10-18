// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A responder with codecs answers the way the call came: objects to a caller
// that sent an object, bytes to one that serialized. The caller decides how a
// call travels; the responder keeps its codecs only to read one that
// serializes.
//
// The witness is a field the codec never encodes: it reaches the caller only
// when the response was passed as an object.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

class Msg implements IRpcSerializable {
  const Msg(this.text, {this.secret = ''});

  final String text;

  /// Never encoded.
  final String secret;

  @override
  Map<String, dynamic> toJson() => {'text': text};

  static Msg fromJson(Map<String, dynamic> json) => Msg(json['text'] as String);
}

const _codec = RpcCodec<Msg>(Msg.fromJson);
const _service = 'AnswerInKind';

final class _Svc extends RpcResponderContract {
  _Svc() : super(_service);

  @override
  void setup() {
    addServerStreamMethod<Msg, Msg>(
      methodName: 'server',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        yield Msg('one', secret: 's1');
        yield Msg('two', secret: 's2');
      },
    );
    addBidirectionalMethod<Msg, Msg>(
      methodName: 'bidi',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield Msg(r.text, secret: 'b');
        }
      },
    );
  }
}

RpcCallerEndpoint _rig() {
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return caller;
}

void main() {
  test('an object request to a codec server stream gets objects', () async {
    final caller = _rig();
    final responses = await caller
        .serverStream<Msg, Msg>(
          serviceName: _service,
          methodName: 'server',
          request: const Msg('go'),
        )
        .toList();

    expect(responses.map((m) => m.secret), ['s1', 's2']);
  });

  test('a serialized request to the same method gets bytes', () async {
    final caller = _rig();
    final responses = await caller
        .serverStream<Msg, Msg>(
          serviceName: _service,
          methodName: 'server',
          request: const Msg('go'),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();

    expect(responses.map((m) => m.text), ['one', 'two']);
    expect(responses.map((m) => m.secret), ['', '']);
  });

  test('an object bidi call gets objects', () async {
    final caller = _rig();
    final responses = await caller
        .bidirectionalStream<Msg, Msg>(
          serviceName: _service,
          methodName: 'bidi',
          requests: Stream.fromIterable(const [Msg('a'), Msg('b')]),
        )
        .toList();

    expect(responses.map((m) => m.text), ['a', 'b']);
    expect(responses.map((m) => m.secret), ['b', 'b']);
  });
}
