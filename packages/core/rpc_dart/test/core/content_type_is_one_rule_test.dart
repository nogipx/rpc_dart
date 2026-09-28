// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Three copies of "is this content-type gRPC?" produced TWO behaviours, because
// each copy decided the ABSENT case for itself. Measured over four inputs and
// three responder layers:
//
//                            HTTP/1.1      HTTP/2        core (channel)
//   (absent)                 415 REFUSED   OK            OK
//   application/grpc         200           OK            OK
//   application/grpc+proto   200           OK            OK
//   text/plain               415 REFUSED   status=3      status=3
//
// So the same request was answered two ways, decided by the wire it arrived on.
// HTTP/2 having "no copy at all" is why it reads as lenient: its metadata goes
// up to core's pipeline, which is the copy it inherits.
//
// There is one rule now, `RpcSecurityPolicy.isAcceptableContentType`, and the
// absent case is a parameter each site states -- with `contentTypeValidation`
// supplying it for the sites that have no reason of their own.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends one call whose outbound `content-type` is [contentType] (null = none)
/// against a responder configured with [mode], and returns `'ok'` or
/// `'status=N message'`.
Future<String> _call(String? contentType, RpcContentTypeValidation mode) async {
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final clientTransport = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
  );
  final serverTransport = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: RpcSecurityPolicy(contentTypeValidation: mode),
  );
  final caller = RpcCallerEndpoint(
    transport: ContentTypeRewritingTransport(
      clientTransport,
      contentType: contentType,
    ),
  );
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_Svc());
  responder.start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
    await clientTransport.close();
    await serverTransport.close();
  });

  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: RpcDataTransferMode.codec,
    );
    return 'ok';
  } on RpcStatusException catch (e) {
    return 'status=${e.statusCode} ${e.message}';
  }
}

void main() {
  group('the rule itself', () {
    test('a present value is judged the same under either mode', () {
      for (final mode in RpcContentTypeValidation.values) {
        for (final accepted in const [
          'application/grpc',
          'application/grpc+proto',
          // RFC 9110 s8.3.1: type and subtype are case-insensitive.
          'Application/GRPC',
          'APPLICATION/GRPC+PROTO',
        ]) {
          expect(
            RpcSecurityPolicy.isAcceptableContentType(accepted, mode),
            isTrue,
            reason: '$accepted under ${mode.name}',
          );
        }
        for (final refused in const [
          'text/plain',
          'application/json',
          'x-application/grpc',
        ]) {
          expect(
            RpcSecurityPolicy.isAcceptableContentType(refused, mode),
            isFalse,
            reason: '$refused under ${mode.name}',
          );
        }
      }
    });

    // The whole point of the mode: ABSENT is the only input it changes.
    test('absent is the only input the mode decides', () {
      expect(
        RpcSecurityPolicy.isAcceptableContentType(
          null,
          RpcContentTypeValidation.lenient,
        ),
        isTrue,
      );
      expect(
        RpcSecurityPolicy.isAcceptableContentType(
          null,
          RpcContentTypeValidation.strict,
        ),
        isFalse,
      );
    });
  });

  group('the policy reaches core', () {
    // WITNESS. Before this key there was no way to ask for the gRPC spec's own
    // rule on any channel transport: absent was accepted and nothing could say
    // otherwise.
    test('strict refuses a request that carries no content-type', () async {
      expect(
        await _call(null, RpcContentTypeValidation.strict),
        'status=${RpcStatus.invalidArgument} Missing content-type for gRPC',
      );
    });

    // GUARD on the default, which is the release-compatibility promise: nothing
    // that worked before this key stops working.
    test('lenient — the default — still accepts it', () async {
      expect(await _call(null, RpcContentTypeValidation.lenient), 'ok');
      expect(
        const RpcSecurityPolicy().contentTypeValidation,
        RpcContentTypeValidation.lenient,
      );
    });

    // CONTROL. The mode must not be a blanket accept/refuse: a present value is
    // judged identically on both sides of it, or the witness above is just
    // "strict breaks everything".
    test('CONTROL: a present value is unaffected by the mode', () async {
      for (final mode in RpcContentTypeValidation.values) {
        expect(await _call('application/grpc', mode), 'ok');
        expect(await _call('application/grpc+proto', mode), 'ok');
        expect(
          await _call('text/plain', mode),
          'status=${RpcStatus.invalidArgument} '
          'Invalid content-type for gRPC: "text/plain"',
        );
      }
    });
  });
}
