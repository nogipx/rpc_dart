// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every caller shape re-implemented "what does this trailer mean", and the
// copies had drifted into different observable behaviour:
//
//   * client-streaming compared the status as TEXT (`!= '0'`), so a peer that
//     spells OK as `00` was a success to five shapes and an error to that one;
//   * "OK with no payload" was INTERNAL on client-streaming and UNAVAILABLE on
//     unary -- not retried on one and retried on the other, for the identical
//     wire event;
//   * the COMPLETION rule was a third disagreement: unary held the payload and
//     let the status decide, while client-streaming and the zero-copy unary
//     path completed on the first payload -- so a payload followed by an error
//     trailer was an error to one shape and a success to the other two.
//
// gRPC's status is authoritative, so the unary shape was right and the rule now
// lives in `RpcCallerTrailer` for all of them.
//
// These sequences cannot be produced by rpc_dart's own responder -- it derives
// payload and status together -- so the peer here is hand-built, which is the
// only way to see what a FOREIGN gRPC peer gets.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Msg implements IRpcSerializable {
  final String value;
  _Msg(this.value);
  factory _Msg.fromJson(Map<String, dynamic> json) =>
      _Msg(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final _codec = RpcCodec<_Msg>(_Msg.fromJson);

/// One framed response message, built with the library's own serializer.
Uint8List _framed(String value) =>
    RpcMessageFrame.encode(_codec.serialize(_Msg(value)));

/// Answers every call with a hand-built sequence.
///
/// [status] is the RAW header value, so `'00'` can be put on the wire.
void _peer(
  IRpcTransport transport, {
  Uint8List? payload,
  Object? directPayload,
  required String status,
  String? message,
}) {
  transport.incomingMessages.listen((incoming) {
    if (incoming.metadata?.methodPath == null) return;
    unawaited(
      Future<void>(() async {
        await transport.sendMetadata(
          incoming.streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        if (payload != null) {
          await transport.sendMessage(incoming.streamId, payload);
        }
        if (directPayload != null) {
          await transport.sendDirectObject(incoming.streamId, directPayload);
        }
        await transport.sendMetadata(
          incoming.streamId,
          RpcMetadata([
            RpcHeader(RpcHeaders.grpcStatus, status),
            if (message != null) RpcHeader(RpcHeaders.grpcMessage, message),
          ]),
          endStream: true,
        );
      }),
    );
  });
}

({RpcCallerEndpoint caller, IRpcTransport peer}) _rig() {
  final pair = RpcInMemoryTransport.pair();
  final caller = RpcCallerEndpoint(transport: pair.$1);
  addTearDown(caller.close);
  return (caller: caller, peer: pair.$2);
}

Future<Object?> _catch(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  group('a payload followed by an error trailer is an ERROR', () {
    // The shape that was already right, kept as the CONTROL and the model.
    test('CONTROL: unary already held the payload', () async {
      final rig = _rig();
      _peer(
        rig.peer,
        payload: _framed('ignore me'),
        status: '${RpcStatus.notFound}',
        message: 'gone',
      );

      final caught = await _catch(
        () => rig.caller.unaryRequest<_Msg, _Msg>(
          serviceName: 'S',
          methodName: 'M',
          request: _Msg('x'),
          requestCodec: _codec,
          responseCodec: _codec,
        ),
      );

      expect(caught, isA<RpcStatusException>());
      expect((caught! as RpcStatusException).statusCode, RpcStatus.notFound);
    });

    test('client-streaming no longer completes on the payload', () async {
      final rig = _rig();
      _peer(
        rig.peer,
        payload: _framed('ignore me'),
        status: '${RpcStatus.notFound}',
        message: 'gone',
      );

      final call = rig.caller.clientStream<_Msg, _Msg>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final caught = await _catch(
        () => call(Stream.value(_Msg('x'))).timeout(const Duration(seconds: 5)),
      );

      expect(
        caught,
        isA<RpcStatusException>(),
        reason:
            'the peer said NOT_FOUND after the payload; completing on the '
            'payload reported success over an error',
      );
      expect((caught! as RpcStatusException).statusCode, RpcStatus.notFound);
    });

    test('the zero-copy unary path no longer returns on the payload', () async {
      final rig = _rig();
      _peer(
        rig.peer,
        directPayload: _Msg('ignore me'),
        status: '${RpcStatus.notFound}',
        message: 'gone',
      );

      final caught = await _catch(
        () => rig.caller
            .unaryRequest<_Msg, _Msg>(
              serviceName: 'S',
              methodName: 'M',
              request: _Msg('x'),
            )
            .timeout(const Duration(seconds: 5)),
      );

      expect(caught, isA<RpcStatusException>());
      expect((caught! as RpcStatusException).statusCode, RpcStatus.notFound);
    });
  });

  group('OK with no payload is INTERNAL on every shape', () {
    // Not UNAVAILABLE: the peer COMPLETED the call and broke the contract, so a
    // retry reaches the same broken peer and spends the caller's deadline.
    test('unary', () async {
      final rig = _rig();
      _peer(rig.peer, status: '${RpcStatus.ok}');

      final caught = await _catch(
        () => rig.caller
            .unaryRequest<_Msg, _Msg>(
              serviceName: 'S',
              methodName: 'M',
              request: _Msg('x'),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 5)),
      );

      expect(caught, isA<RpcStatusException>());
      expect(
        (caught! as RpcStatusException).statusCode,
        RpcStatus.internal,
        reason: 'unary used to fall through to onDone and report UNAVAILABLE',
      );
    });

    test('client-streaming', () async {
      final rig = _rig();
      _peer(rig.peer, status: '${RpcStatus.ok}');

      final call = rig.caller.clientStream<_Msg, _Msg>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final caught = await _catch(
        () => call(Stream.value(_Msg('x'))).timeout(const Duration(seconds: 5)),
      );

      expect(caught, isA<RpcStatusException>());
      expect((caught! as RpcStatusException).statusCode, RpcStatus.internal);
    });
  });

  // The status is a NUMBER. `!= '0'` read a peer's `00` as an error on exactly
  // one shape.
  test('a peer that spells OK as "00" is a success, not an error', () async {
    final rig = _rig();
    _peer(rig.peer, payload: _framed('fine'), status: '00');

    final call = rig.caller.clientStream<_Msg, _Msg>(
      serviceName: 'S',
      methodName: 'M',
      requestCodec: _codec,
      responseCodec: _codec,
    );

    final response = await call(
      Stream.value(_Msg('x')),
    ).timeout(const Duration(seconds: 5));

    expect(response.value, 'fine');
  });

  // GUARD: the ordinary path must still work on every shape. Without this, a
  // caller that failed everything would pass every test above.
  group('GUARD: an ordinary OK call still succeeds', () {
    test('unary', () async {
      final rig = _rig();
      _peer(rig.peer, payload: _framed('ok'), status: '${RpcStatus.ok}');

      final response = await rig.caller
          .unaryRequest<_Msg, _Msg>(
            serviceName: 'S',
            methodName: 'M',
            request: _Msg('x'),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));

      expect(response.value, 'ok');
    });

    test('client-streaming', () async {
      final rig = _rig();
      _peer(rig.peer, payload: _framed('ok'), status: '${RpcStatus.ok}');

      final call = rig.caller.clientStream<_Msg, _Msg>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final response = await call(
        Stream.value(_Msg('x')),
      ).timeout(const Duration(seconds: 5));

      expect(response.value, 'ok');
    });
  });

  group('a closed endpoint refuses every call shape', () {
    // The pre-flight guard covered ping, unaryRequest and serverStream and not
    // the other two, so a call on a closed endpoint got as far as building a
    // context and reserving a stream id.
    //
    // Asserted on `what`, not just the type: the closed TRANSPORT underneath
    // also throws RpcClosedException, so `isA<RpcClosedException>()` alone
    // passes with the endpoint guard removed and witnesses nothing.
    Matcher refusedByTheEndpoint() => throwsA(
      isA<RpcClosedException>().having((e) => e.what, 'what', 'Endpoint'),
    );

    late RpcCallerEndpoint caller;

    setUp(() async {
      final pair = RpcInMemoryTransport.pair();
      caller = RpcCallerEndpoint(transport: pair.$1);
      await caller.close();
    });

    test('clientStream', () async {
      final call = caller.clientStream<_Msg, _Msg>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      await expectLater(call(Stream.value(_Msg('x'))), refusedByTheEndpoint());
    });

    test('bidirectionalStream', () {
      expect(
        () => caller.bidirectionalStream<_Msg, _Msg>(
          serviceName: 'S',
          methodName: 'M',
          requests: Stream.value(_Msg('x')),
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        refusedByTheEndpoint(),
      );
    });

    // CONTROL: the three that always had the guard still have it.
    test('CONTROL: unaryRequest', () {
      expect(
        () => caller.unaryRequest<_Msg, _Msg>(
          serviceName: 'S',
          methodName: 'M',
          request: _Msg('x'),
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        refusedByTheEndpoint(),
      );
    });

    test('CONTROL: serverStream', () {
      expect(
        () => caller.serverStream<_Msg, _Msg>(
          serviceName: 'S',
          methodName: 'M',
          request: _Msg('x'),
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        refusedByTheEndpoint(),
      );
    });
  });
}
