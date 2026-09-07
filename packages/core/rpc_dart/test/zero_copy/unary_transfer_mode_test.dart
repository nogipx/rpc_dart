// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What a unary call does on a transport that can pass objects.
//
// `UnaryCaller` used to branch on `transport.supportsZeroCopy` ALONE, so a
// method that explicitly declared RpcDataTransferMode.codec had its codecs
// skipped anyway. Measured over the isolate transport with codecs on both ends
// and maxMessageLengthBytes: 256 KiB:
//
//   a 2 MiB response       DELIVERED  (no bytes exist, so no limit does)
//   a field toJson OMITS   ARRIVED    (`secret=hunter2` crossed a process
//                                      boundary the codec exists to control)
//
// Removing the fast path outright was the wrong correction -- it took `auto`
// with it, and `auto` is the default and worth 413 us against 502 us per round
// trip on isolate. The rule now: `auto` (and `zeroCopy`) keep the object path,
// only an explicit `codec` serializes.
//
// This file pins BOTH halves, because either alone is satisfiable by a wrong
// implementation.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class Msg implements IRpcSerializable {
  const Msg(this.text, {this.secret = ''});

  final String text;

  /// Never encoded. Arriving on the far side means the codec was skipped.
  final String secret;

  @override
  Map<String, dynamic> toJson() => {'text': text};

  static Msg fromJson(Map<String, dynamic> json) => Msg(json['text'] as String);
}

const _codec = RpcCodec<Msg>(Msg.fromJson);
const _service = 'TransferMode';

final class _Svc extends RpcResponderContract {
  _Svc() : super(_service);

  @override
  void setup() {
    addUnaryMethod<Msg, Msg>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => Msg('got:${r.secret}'),
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  List<RpcTransportMessage> serverSaw,
});

_Rig _rig() {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  final serverSaw = <RpcTransportMessage>[];
  serverTransport.incomingMessages.listen(serverSaw.add);

  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller: caller, serverSaw: serverSaw);
}

Future<Msg> _call(_Rig rig, RpcDataTransferMode mode) =>
    rig.caller.unaryRequest<Msg, Msg>(
      serviceName: _service,
      methodName: 'echo',
      request: const Msg('go', secret: 'hunter2'),
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: mode,
    );

void main() {
  test('auto passes the object when the transport can', () async {
    // The default, and the fast path. In-memory and isolate both report
    // supportsZeroCopy.
    final rig = _rig();

    final response = await _call(rig, RpcDataTransferMode.auto);

    expect(
      response.text,
      'got:hunter2',
      reason: 'the object itself crossed, so the field is still on it',
    );
    expect(rig.serverSaw.where((m) => m.isDirect), isNotEmpty);
    expect(rig.serverSaw.where((m) => m.isSerialized), isEmpty);
  });

  test('an explicit codec serializes, and the codec is honoured', () async {
    // WITNESS. Pre-fix this behaved exactly like `auto` -- the declared mode was
    // never consulted.
    final rig = _rig();

    final response = await _call(rig, RpcDataTransferMode.codec);

    expect(
      response.text,
      'got:',
      reason: 'toJson omits `secret`, so it must not reach the handler',
    );
    expect(rig.serverSaw.where((m) => m.isSerialized), isNotEmpty);
    expect(rig.serverSaw.where((m) => m.isDirect), isEmpty);
  });

  test('GUARD: zeroCopy keeps the object path too', () async {
    // The third mode. Only `codec` is meant to force bytes.
    final rig = _rig();

    final response = await _call(rig, RpcDataTransferMode.zeroCopy);

    expect(response.text, 'got:hunter2');
    expect(rig.serverSaw.where((m) => m.isDirect), isNotEmpty);
  });

  test('GUARD: a contract in codec mode gets codec behaviour', () async {
    // The route a real caller takes: RpcCallerContract passes its own
    // dataTransferMode down, which is the whole point of threading it.
    final rig = _rig();
    final contract = _CallerContract(rig.caller);

    final response = await contract.echo(const Msg('go', secret: 'hunter2'));

    expect(response.text, 'got:');
    expect(rig.serverSaw.where((m) => m.isSerialized), isNotEmpty);
  });
}

final class _CallerContract extends RpcCallerContract {
  _CallerContract(RpcCallerEndpoint endpoint)
    : super(_service, endpoint, dataTransferMode: RpcDataTransferMode.codec);

  Future<Msg> echo(Msg request) => callUnary<Msg, Msg>(
    methodName: 'echo',
    request: request,
    requestCodec: _codec,
    responseCodec: _codec,
  );
}
