// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller has always SENT `x-request-id`, and the responder never read it.
//
// So the two sides logged different request ids for one call and their logs
// could not be joined on it -- while `x-trace-id`, which the responder does
// adopt, joined fine. That asymmetry inside one pair of headers is what named
// this: both are protocol-reserved, both are sent by the caller, and only one
// was listened for.
//
// Adopting it also removes a token: a context token costs three draws from
// Random.secure(), and a unary call spent three of them. Measured on the
// in-memory pair, the endpoint layer's share of a round trip went 165us -> 138us
// once the responder stopped minting an id it was about to have handed to it.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  String? seenRequestId;
  String? seenTraceId;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async {
        seenRequestId = context?.requestId;
        seenTraceId = context?.traceId;
        return request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, _Svc svc});

Future<_Rig> _connect() async {
  final (clientT, serverT) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: clientT);
  final responder = RpcResponderEndpoint(transport: serverT);
  final svc = _Svc();
  responder.registerServiceContract(svc);
  responder.start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
    await clientT.close();
    await serverT.close();
  });
  return (caller: caller, svc: svc);
}

void main() {
  test('the responder adopts the request id the caller sent', () async {
    final rig = await _connect();
    final context = RpcContext.empty();

    await rig.caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: context,
    );

    expect(
      rig.svc.seenRequestId,
      context.requestId,
      reason: 'both sides must name the same call in their logs',
    );
  });

  test('GUARD: the trace id still joins too', () async {
    // The half that already worked. It is here so a change to one adoption
    // path cannot quietly break the other.
    final rig = await _connect();
    final context = RpcContext.empty().withTraceId('trace_pinned');

    await rig.caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: context,
    );

    expect(rig.svc.seenTraceId, 'trace_pinned');
  });

  test('GUARD: a peer that sends none still gets an id', () async {
    // A foreign peer speaking the frame protocol need not send either header;
    // the responder must still have a usable id rather than an empty string.
    final (clientT, serverT) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: serverT);
    final svc = _Svc();
    responder.registerServiceContract(svc);
    responder.start();
    addTearDown(() async {
      await responder.close();
      await clientT.close();
      await serverT.close();
    });

    final id = clientT.createStream();
    clientT.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
    await clientT.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'echo'));
    await clientT.sendMessage(
      id,
      RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
      endStream: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(svc.seenRequestId, isNotNull);
    expect(svc.seenRequestId, startsWith('req_'));
  });

  test('GUARD: a context keeps one id once read', () async {
    // The id is generated lazily now, so this pins that it is STABLE: reading
    // it twice, and copying the context, must not mint a new one.
    final context = RpcContext.empty();
    final first = context.requestId;
    expect(context.requestId, first);
    expect(context.withTraceId('t').requestId, first);
    expect(context.withValue('k', 'v').requestId, first);
  });
}
