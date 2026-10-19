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

import 'dart:async';

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
    addServerStreamMethod<Msg, Msg>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        yield Msg('zc:${r.text}');
      },
    );
    addClientStreamMethod<Msg, Msg>(
      methodName: 'client',
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {}
        return const Msg('zc:done');
      },
    );
    addBidirectionalMethod<Msg, Msg>(
      methodName: 'bidi',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield Msg('zc:${r.text}');
        }
      },
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
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
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

/// A call with codecs serializes; one without passes the object.
Future<Msg> _call(
  RpcCallerEndpoint caller, {
  required String service,
  required bool withCodecs,
}) => caller.unaryRequest<Msg, Msg>(
  serviceName: service,
  methodName: 'echo',
  request: const Msg('hi'),
  requestCodec: withCodecs ? _codec : null,
  responseCodec: withCodecs ? _codec : null,
);

final _mismatch = throwsA(
  isA<RpcStatusException>().having(
    (e) => e.message,
    'message',
    contains('Transfer-mode mismatch'),
  ),
);

void main() {
  // The three STREAMING shapes need no new API to reach the mismatch: their
  // callers pick the mode from whether codecs were passed, so a caller with
  // codecs against a zero-copy method has always sent bytes into a responder
  // that reads directPayload. Measured before the fix, all four shapes:
  //
  //   unary        status 13, 38 ms      clientStream status 13, 11 ms
  //   bidi         status 13,  6 ms      serverStream SILENCE, 6 s
  //
  // Only the server stream dropped it -- its request subscription logged the
  // error and answered nothing.
  test(
    'serverStream: bytes to a zero-copy method are ANSWERED',
    () async {
      final caller = _rig();

      await expectLater(
        caller
            .serverStream<Msg, Msg>(
              serviceName: _zeroCopyService,
              methodName: 'server',
              request: const Msg('hi'),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>()
            .timeout(const Duration(seconds: 15)),
        _mismatch,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'clientStream: bytes to a zero-copy method are ANSWERED',
    () async {
      final caller = _rig();
      final requests = StreamController<Msg>();
      final call = caller.clientStream<Msg, Msg>(
        serviceName: _zeroCopyService,
        methodName: 'client',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      requests.add(const Msg('hi'));
      await requests.close();

      await expectLater(call.timeout(const Duration(seconds: 15)), _mismatch);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'bidi: bytes to a zero-copy method are ANSWERED',
    () async {
      final caller = _rig();
      final requests = StreamController<Msg>();
      final responses = caller.bidirectionalStream<Msg, Msg>(
        serviceName: _zeroCopyService,
        methodName: 'bidi',
        requests: requests.stream,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      requests.add(const Msg('hi'));

      await expectLater(
        responses.drain<void>().timeout(const Duration(seconds: 15)),
        _mismatch,
      );
      await requests.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a matching zero-copy server stream still works',
    () async {
      // Pairs with the witness above: without it, a responder that refused every
      // request stream would pass.
      final caller = _rig();

      final items = await caller
          .serverStream<Msg, Msg>(
            serviceName: _zeroCopyService,
            methodName: 'server',
            request: const Msg('hi'),
          )
          .toList()
          .timeout(const Duration(seconds: 15));

      expect(items.map((m) => m.text).toList(), ['zc:hi']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

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
        withCodecs: false,
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
        withCodecs: true,
      ).timeout(const Duration(seconds: 15));

      expect(response.text, 'codec:hi');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // Every later frame of a mismatched call would repeat the record, and the
  // peer chooses how many frames it sends.
  test(
    'a mismatched call is logged once however many frames it sends',
    () async {
      final records = <LogEvent>[];
      final controller = LogController(minLevel: RpcLogLevel.error);
      controller.stream.listen((r) {
        if (r is LogEvent) records.add(r);
      });
      addTearDown(controller.dispose);
      final (clientTransport, serverTransport) =
          RpcChannelTransport.memoryPair();
      final responder = RpcResponderEndpoint(
        transport: serverTransport,
        logController: controller,
      )..registerServiceContract(_ZeroCopySvc());
      responder.start();
      final caller = RpcCallerEndpoint(transport: clientTransport);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final call = caller.clientStream<Msg, Msg>(
        serviceName: _zeroCopyService,
        methodName: 'client',
        requestCodec: _codec,
        responseCodec: _codec,
      )(Stream.fromIterable(List.generate(5, (i) => Msg('$i'))));
      await expectLater(call.timeout(const Duration(seconds: 15)), _mismatch);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        records.where((r) => r.message.startsWith('transfer_mode_mismatch')),
        hasLength(1),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
