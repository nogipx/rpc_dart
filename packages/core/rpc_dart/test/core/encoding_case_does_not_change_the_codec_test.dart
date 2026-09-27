// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcGrpcCompression` has always normalised before comparing (`trim()
// .toLowerCase()`, RFC 9110), and ELEVEN sites outside it compared a RAW header
// value against the lower-case `identity` constant. The two disagreed on
// `Identity`, and the disagreement was not inert:
//
//   isSupported('Identity')     -> true   (normalises)  so nothing is refused
//   'Identity' != 'identity'    -> true                 so compression is ON
//   compress(enc: 'Identity')   -> unchanged (normalises to identity)
//
// which puts the compressed FLAG on an uncompressed message. Measured over a real
// socket from the library's own caller, with the encoding in the call context —
// the SUPPORTED way to select it, `_context?.getHeader(grpcEncoding)`:
//
//   identity  -> OK
//   Identity  -> status=13 Internal server error
//
// One shared accessor now answers the question: `RpcGrpcCompression.isIdentity`.

import 'package:rpc_dart/rpc_dart.dart';
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

/// One unary call with `grpc-encoding` spelled exactly as given.
Future<String> _callWith(String? encoding) async {
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

  try {
    final r = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: encoding == null
          ? null
          : RpcContext.withHeaders({'grpc-encoding': encoding}),
    );
    return r.value;
  } on RpcStatusException catch (e) {
    return 'status=${e.statusCode}';
  }
}

void main() {
  group('the case of grpc-encoding does not change which codec is used', () {
    // NOT a witness, and it says so: over a channel pair this passes on BOTH
    // sides of the fix, because compress and decompress both normalise, so the
    // flag-on-uncompressed-bytes round trips harmlessly in process. The
    // behavioural witness is in rpc_dart_http2
    // (`identity_case_round_trips_test.dart`), where the responder's parser is
    // built from the encoding the pipeline read and the mismatch is fatal.
    //
    // Kept because it pins the CONTRACT at this layer: whichever spelling a
    // caller uses, the call works.
    test('Identity behaves exactly like identity', () async {
      expect(
        await _callWith('Identity'),
        'saw:x',
        reason:
            'the registry has always been case-insensitive; a comparison '
            'against the lower-case constant is a second, stricter answer to '
            'the same question',
      );
    });

    // CONTROL. The spelling the library itself always sends. If this ever fails
    // the witness is measuring the harness, not the case.
    test('CONTROL: identity works', () async {
      expect(await _callWith('identity'), 'saw:x');
    });

    // CONTROL. Absent means identity per the spec, and takes a different branch
    // (the null one) from either spelling.
    test('CONTROL: absent works', () async {
      expect(await _callWith(null), 'saw:x');
    });

    // The accessor itself, on the spellings RFC 9110 admits. Cheap, and it is
    // what the eleven sites now depend on.
    test('isIdentity accepts every spelling of identity, and nothing else', () {
      expect(RpcGrpcCompression.isIdentity(null), isTrue);
      expect(RpcGrpcCompression.isIdentity('identity'), isTrue);
      expect(RpcGrpcCompression.isIdentity('Identity'), isTrue);
      expect(RpcGrpcCompression.isIdentity('IDENTITY'), isTrue);
      expect(RpcGrpcCompression.isIdentity('  identity  '), isTrue);
      expect(RpcGrpcCompression.isIdentity('gzip'), isFalse);
      expect(RpcGrpcCompression.isIdentity('identityx'), isFalse);
    });
  });
}
