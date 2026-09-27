// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcGrpcCompression` has always normalised before comparing (RFC 9110), and
// eleven sites outside it compared a RAW `grpc-encoding` value against the
// lower-case `identity` constant. On `Identity` the two disagreed, and the
// disagreement was not inert:
//
//   isSupported('Identity')   -> true   (normalises)  so nothing is refused
//   'Identity' != 'identity'  -> true                 so compression is ON
//   compress(enc:'Identity')  -> unchanged            (normalises to identity)
//
// which puts the compressed FLAG on an uncompressed message.
//
// THE WITNESS BELONGS HERE, not in core. Over a channel pair the same call round
// trips harmlessly on both sides of the fix, because compress and decompress both
// normalise in process. Over http2 the responder's parser is built from the
// encoding the pipeline read, and the mismatch is fatal:
//
//   own caller, grpc-encoding=identity  -> OK
//   own caller, grpc-encoding=Identity  -> status=13 Internal server error
//
// The encoding is set the supported way: a header on the call context, which is
// what `_context?.getHeader(grpcEncoding)` reads.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _EchoService extends RpcResponderContract {
  _EchoService() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async =>
          'saw:${request.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttp2Server server;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_EchoService()),
    );
    await server.start();
  });

  tearDown(() => server.stop());

  Future<String> callWith(String encoding, {String payload = 'x'}) async {
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
    });

    try {
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: payload.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withHeaders({'grpc-encoding': encoding}),
          )
          .timeout(const Duration(seconds: 10));
      return r.value;
    } on RpcStatusException catch (e) {
      return 'status=${e.statusCode}';
    }
  }

  // WITNESS. Before the fix this read status=13.
  test(
    'grpc-encoding: Identity round trips over http2',
    () async {
      expect(
        await callWith('Identity'),
        'saw:x',
        reason:
            'the registry is case-insensitive, so a capitalised identity names '
            'the same codec; treating it as compression sets the flag on bytes '
            'nothing compressed',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL. The spelling the library itself always sends, which worked before
  // and must still. If this fails, the witness is measuring the harness.
  test(
    'CONTROL: grpc-encoding: identity round trips',
    () async {
      expect(await callWith('identity'), 'saw:x');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // THE GUARD WHOSE ABSENCE LET A REGRESSION SHIP (round 457).
  //
  // Nothing in this suite exercised a genuinely COMPRESSED message over http2, so
  // round 455 removed `ensureGrpcFrame`'s heuristic on the premise that
  // `RpcMessageParser` always emits de-framed bodies -- true except in the one
  // branch http2 always takes. These transports build their parser with no
  // decompressor, so for a compressed message the parser re-frames the payload
  // itself (`encode(payload, compressed: true)`) and the heuristic is what stops
  // it being framed twice, which would lose the compressed bit.
  //
  //     unconditional framing   gzip -> status=13 INTERNAL
  //     the heuristic           gzip -> OK
  //
  // A body worth compressing, so the two framings differ in size and the failure
  // cannot hide in a payload small enough to be incompressible.
  for (final encoding in ['gzip', 'GZIP']) {
    test(
      'a COMPRESSED message round trips: grpc-encoding: $encoding',
      () async {
        expect(
          await callWith(encoding, payload: 'y' * 4096),
          'saw:${'y' * 4096}',
          reason:
              'http2 parses with no decompressor, so the parser hands up an '
              'already-framed compressed message; framing it again drops the '
              'compressed bit and the codec then reads gzip bytes',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
