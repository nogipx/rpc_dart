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

/// One call from a peer that speaks the frame protocol but is not rpc_dart:
/// `forClientRequest` carries content-type and grpc-accept-encoding and no
/// correlation headers at all, so the empty [headers] IS the foreign shape.
Future<_Svc> _foreignPeerCall(Map<String, String> headers) async {
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

  final base = RpcMetadata.forClientRequest('Svc', 'echo');
  final id = clientT.createStream();
  clientT.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await clientT.sendMetadata(
    id,
    RpcMetadata([
      ...base.headers,
      for (final e in headers.entries) RpcHeader(e.key, e.value),
    ], methodPath: base.methodPath),
  );
  await clientT.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
    endStream: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return svc;
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

  // WITNESS. The responder used to MINT its trace id whenever none arrived, where
  // the caller side derives one -- and a peer that sends no `x-trace-id` sends no
  // `x-request-id` either, since both are ours rather than gRPC's. So a foreign
  // peer cost the responder two tokens where an rpc_dart peer costs it none.
  //
  // Asserted as identity rather than as a count: two tokens are never equal, so a
  // trace id carrying the request id's own body IS the proof nothing was minted.
  test('a peer that sends neither header gets a DERIVED trace id', () async {
    final svc = await _foreignPeerCall(const {});

    expect(svc.seenRequestId, startsWith('req_'));
    expect(
      svc.seenTraceId,
      'trace_${svc.seenRequestId!.substring(4)}',
      reason:
          'the trace id must come from the request id just minted, not from a '
          'second token',
    );
  });

  // CONTROL. `traceIdFor` can only derive from an id of ours, so this arm MUST
  // still mint -- and if it ever stops, the witness above is passing because
  // nothing mints at all rather than because the derivation works.
  test('CONTROL: a foreign request id still gets a fresh trace id', () async {
    final svc = await _foreignPeerCall(const {
      'x-request-id': 'not-one-of-ours',
    });

    expect(svc.seenRequestId, 'not-one-of-ours');
    expect(svc.seenTraceId, startsWith('trace_'));
    expect(
      svc.seenTraceId,
      isNot('trace_one-of-ours'),
      reason: 'nothing may be derived from an id this library did not mint',
    );
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
