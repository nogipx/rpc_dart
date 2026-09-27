// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two refusals sit either side of the same closed-stream guard in
// `responder_pipeline`, and only one of them explained its position:
//
//   the drain refusal    UNAVAILABLE, tested BEFORE the guard, no comment
//   the closed-stream guard
//   the ceiling refusal  RESOURCE_EXHAUSTED, AFTER the guard, with a comment
//                        saying why: "Checked after the closed-stream guard, so
//                        a late frame for a torn-down id cannot burn a slot"
//
// The drain branch got the opposite order, and it was the bug the other comment
// exists to prevent: a TRAILING frame on an already-completed stream was answered
// UNAVAILABLE, which is a SECOND terminal status on a stream the peer had already
// been told was OK.
//
//   draining, late frame on a closed id   status=14 "Server is shutting down"
//   NOT draining, same frame              ignored
//
// The drain check is now ordered with the ceiling.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _EchoService extends RpcResponderContract {
  _EchoService() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Completes one call, optionally marks the endpoint draining, then delivers a
/// TRAILING metadata-only frame on the finished id. Returns the statuses the peer
/// was sent afterwards.
Future<List<String>> _lateFrameOnAClosedStream({required bool draining}) async {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_EchoService());
  responder.start();
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await responder.close().catchError((Object _) {});
    await client.close().catchError((Object _) {});
    await server.close().catchError((Object _) {});
  });

  // A COMPLETE call, so its id lands in the closed-stream set. Stream 1: client
  // ids are odd and this is the first call, so the late frame below is
  // deliberately NOT a fresh stream.
  await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'echo',
    request: 'hi'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final answers = <String>[];
  final sub = client.incomingMessages.listen((m) {
    final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    if (status != null) answers.add(status);
  });
  addTearDown(sub.cancel);

  if (draining) responder.markDraining();

  // Metadata-only, no methodPath: exactly what the closed-stream guard exists
  // to ignore.
  await client.sendMetadata(1, RpcMetadata([RpcHeader('x-late', 'true')]));
  await Future<void>.delayed(const Duration(milliseconds: 400));
  return answers;
}

void main() {
  group('draining does not answer a stream that already finished', () {
    // WITNESS. Before the fix this read ['14'].
    test(
      'a trailing frame on a closed id is ignored while draining',
      () async {
        expect(
          await _lateFrameOnAClosedStream(draining: true),
          isEmpty,
          reason:
              'the peer was already told this stream was OK; answering it '
              'UNAVAILABLE puts a second terminal status on one stream',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // CONTROL. The same frame with the endpoint NOT draining was always
    // ignored. If this ever fails, the witness is measuring the guard rather
    // than the drain ordering.
    test(
      'CONTROL: the same frame is ignored when not draining',
      () async {
        expect(await _lateFrameOnAClosedStream(draining: false), isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // GUARD, and it is load-bearing: moving the check later must not disable
    // it. A genuinely NEW stream is still refused while draining.
    test(
      'GUARD: a NEW stream is still refused while draining',
      () async {
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server);
        responder.registerServiceContract(_EchoService());
        responder.start();
        addTearDown(() async {
          await responder.close().catchError((Object _) {});
          await client.close().catchError((Object _) {});
          await server.close().catchError((Object _) {});
        });

        final answers = <String>[];
        final sub = client.incomingMessages.listen((m) {
          final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
          if (status != null) answers.add(status);
        });
        addTearDown(sub.cancel);

        responder.markDraining();

        final id = client.createStream();
        await client.sendMetadata(
          id,
          RpcMetadata.forClientRequest('Svc', 'echo'),
        );
        await client.sendMessage(
          id,
          RpcMessageFrame.encode(_codec.serialize('hi'.rpc)),
          endStream: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(
          answers,
          contains(RpcStatus.unavailable.toString()),
          reason: 'a drain that stops refusing new calls is not a drain',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
