// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A refusal's own answer must satisfy the rule that refused -- and `grpc-message`
// is a header value like any other, so a long message was rejected by
// `maxHeaderValueBytes` and the whole trailer went nowhere.
//
// Measured over the isolate transport with `maxHeaderValueBytes: 64`:
//
//   handler throws RpcStatusException(7, '<70 chars>')
//     before : status 13 "Responder dispatch failed"   <- the code the service
//              CHOSE, replaced by a generic one
//     after  : status 7 with the message trimmed
//
//   round 171's mode-mismatch diagnosis (~200 chars)
//     before : SILENCE, no answer in 6 s
//     after  : status 13, trimmed
//
// The trailer now trims the message to the policy it is about to be validated
// against. The STATUS is what must survive; the text is what gives way.
//
// Not covered, and deliberately: at `maxHeaderValueBytes: 16` no call happens at
// all, because the caller's own `x-request-id` does not fit either. A cap that
// blocks ordinary traffic is a configuration error, not this behaviour.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Comfortably longer than the caps under test.
const _longMessage =
    'a deliberate explanation that is far longer than the header cap allows';

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'deny',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async =>
          throw RpcStatusException(RpcStatus.permissionDenied, _longMessage),
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
    );
  }
}

RpcCallerEndpoint _rig(RpcSecurityPolicy policy) {
  final (clientChannel, serverChannel) = RpcFrameMultiplexedChannel.pair(
    policy: policy,
  );
  final responder = RpcResponderEndpoint(
    transport: RpcChannelTransport(
      channel: serverChannel,
      isClient: false,
      policy: policy,
    ),
  );
  responder.registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport(
      channel: clientChannel,
      isClient: true,
      policy: policy,
    ),
  );
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return caller;
}

Future<Object?> _errorOf(RpcCallerEndpoint caller, String method) async {
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          request: 'hi'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  test(
    "a handler's chosen status survives a tight header cap",
    () async {
      // WITNESS. Pre-fix the trailer failed validation, the throw escaped into
      // _detachedDispatch, and the peer was told INTERNAL "Responder dispatch
      // failed" -- the wrong code AND none of the reason.
      final caller = _rig(const RpcSecurityPolicy(maxHeaderValueBytes: 64));

      final error = await _errorOf(caller, 'deny');

      expect(error, isA<RpcStatusException>());
      expect(
        (error! as RpcStatusException).statusCode,
        RpcStatus.permissionDenied,
        reason: 'the code the service chose must reach the peer',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'the message is trimmed, not dropped',
    () async {
      // What gives way is the text, and only as much as it must.
      final caller = _rig(const RpcSecurityPolicy(maxHeaderValueBytes: 64));

      final error = await _errorOf(caller, 'deny');

      final message = (error! as RpcStatusException).message;
      expect(message, isNotEmpty);
      expect(
        _longMessage,
        startsWith(message),
        reason: 'a prefix of what the handler said, not something else',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a generous cap delivers the whole message',
    () async {
      // Pairs with the witnesses: trimming must not happen when nothing requires
      // it, or the first test would pass on an implementation that always
      // truncated.
      final caller = _rig(const RpcSecurityPolicy());

      final error = await _errorOf(caller, 'deny');

      expect(
        (error! as RpcStatusException).statusCode,
        RpcStatus.permissionDenied,
      );
      expect((error as RpcStatusException).message, _longMessage);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: an ordinary call is unaffected by the tight cap',
    () async {
      // The cap is small but workable; without this the witnesses could pass on a
      // transport that refused everything.
      final caller = _rig(const RpcSecurityPolicy(maxHeaderValueBytes: 64));

      final response = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ok',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(response.value, 'ok');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
