// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The two ends of a call take their transfer mode from their OWN contract, so
// they can disagree. A caller in RpcDataTransferMode.codec sends bytes to a
// method registered zero-copy, whose processor reads `directPayload` and finds
// none -- and both sides of that path used to log a warning and `return`.
//
// Measured over the isolate transport, four mode combinations:
//
//   auto  + codecs -> codec contract      answered in 21 ms
//   codec + codecs -> codec contract      answered in 10 ms
//   no codecs      -> zeroCopy contract   answered in 10 ms
//   codec + codecs -> zeroCopy contract   NO ANSWER IN 6 s
//
// Round 170 is what made the last row reachable: before it, a unary call on a
// zero-copy transport always sent the raw object, so a zero-copy responder
// always got one. The silence itself is older than that.
//
// The mirror direction has never had the problem -- a direct object arriving at
// a serialized processor is cast and delivered, which is how a zero-copy caller
// talks to a codec-declared responder.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class Msg implements IRpcSerializable {
  const Msg(this.text);

  final String text;

  @override
  Map<String, dynamic> toJson() => {'text': text};

  static Msg fromJson(Map<String, dynamic> json) => Msg(json['text'] as String);
}

const _codec = RpcCodec<Msg>(Msg.fromJson);
const _zeroCopyService = 'svc.ZeroCopy';
const _codecService = 'svc.Codec';

/// No codecs: the pipeline builds the zero-copy responder.
final class _ZeroCopySvc extends RpcResponderContract {
  _ZeroCopySvc()
    : super(_zeroCopyService, dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    addUnaryMethod<Msg, Msg>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => Msg('zc:${r.text}'),
    );
  }
}

final class _CodecSvc extends RpcResponderContract {
  _CodecSvc()
    : super(_codecService, dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    addUnaryMethod<Msg, Msg>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => Msg('codec:${r.text}'),
    );
  }
}

RpcCallerEndpoint _rig() {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_ZeroCopySvc());
  responder.registerServiceContract(_CodecSvc());
  responder.start();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return caller;
}

Future<Msg> _call(
  RpcCallerEndpoint caller, {
  required String service,
  required RpcDataTransferMode mode,
  required bool withCodecs,
}) => caller.unaryRequest<Msg, Msg>(
  serviceName: service,
  methodName: 'echo',
  request: const Msg('hi'),
  requestCodec: withCodecs ? _codec : null,
  responseCodec: withCodecs ? _codec : null,
  transferMode: mode,
);

void main() {
  test(
    'bytes to a zero-copy method are ANSWERED, not dropped',
    () async {
      // WITNESS. Pre-fix this produced no reply at all -- the caller waited out
      // its own deadline with nothing to diagnose.
      final caller = _rig();

      await expectLater(
        _call(
          caller,
          service: _zeroCopyService,
          mode: RpcDataTransferMode.codec,
          withCodecs: true,
        ).timeout(const Duration(seconds: 15)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Transfer-mode mismatch'),
              contains(_zeroCopyService),
              contains('zero-copy'),
            ),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a matching zero-copy call still works',
    () async {
      // Without this the witness would pass on a responder that refused
      // everything.
      final caller = _rig();

      final response = await _call(
        caller,
        service: _zeroCopyService,
        mode: RpcDataTransferMode.auto,
        withCodecs: false,
      ).timeout(const Duration(seconds: 15));

      expect(response.text, 'zc:hi');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: the mirror direction is unaffected',
    () async {
      // A zero-copy CALLER against a codec-declared responder: the direct object
      // is cast and delivered. This is the pre-170 norm and must stay working.
      final caller = _rig();

      final response = await _call(
        caller,
        service: _codecService,
        mode: RpcDataTransferMode.auto,
        withCodecs: true,
      ).timeout(const Duration(seconds: 15));

      expect(response.text, 'codec:hi');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: matching codec mode still works',
    () async {
      final caller = _rig();

      final response = await _call(
        caller,
        service: _codecService,
        mode: RpcDataTransferMode.codec,
        withCodecs: true,
      ).timeout(const Duration(seconds: 15));

      expect(response.text, 'codec:hi');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
