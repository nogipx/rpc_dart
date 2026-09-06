// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An UNCAUGHT handler exception used to be stringified onto the wire, so the
// caller received the Dart exception type and its message. Exception messages
// routinely carry connection strings, SQL, file paths and record ids.
//
// Measured over a real HTTP/2 socket with a handler throwing a StateError whose
// text stood in for a secret. All four call shapes leaked it:
//
//   unary        LEAKS  Request processing error: Bad state: <secret>
//   serverStream LEAKS  Bad state: <secret>
//   clientStream LEAKS  Bad state: <secret>
//   bidi         LEAKS  Bad state: <secret>
//   explicit     clean  you may not do that   (the handler's own words)
//
// Found from OUTSIDE the ecosystem, which is why it had gone unnoticed: a real
// gRPC client (grpcurl) against RpcHttp2Server reported
// `Internal: Request processing error: Bad state: handler blew up: x`. Any
// unauthenticated peer could read it.
//
// The line was first drawn at Dart's own: an Error is a BUG, an Exception is a
// condition someone CHOSE to signal, so Exceptions still travelled. That is no
// longer the rule. It does not survive third-party libraries -- a database
// driver throws with the failing query in it, an HTTP client with the URL and
// sometimes a token -- and an allow-list of leaky types cannot be written,
// because most belong to packages this library has never heard of.
//
// `wireStatusFor` is now DEFAULT DENY: only an explicit RpcStatusException and
// rpc_dart's own RpcException hierarchy travel. Everything else, Error or
// Exception, gets kInternalErrorWireMessage.
//
// Two things had to keep working, and the gate caught both when they did not:
//
//   rpc_context_integration_test  a handler putting a trace id in front of the
//                                 caller -- now via RpcStatusException, which
//                                 is the supported way to say anything
//   compressed_payload_honours_policy_test
//                                 expects "max: 1048576" -- rpc_dart's own
//                                 framing diagnostic, which is what tells a
//                                 peer to send less. A decompressor throws its
//                                 OWN library's type, so the parser now rewraps
//                                 that as an RpcException naming the limit.
//
// The cause is NOT lost either way: every one of these sites logs it with its
// stack trace before answering.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _secret = 'SECRET-db-password-hunter2-/var/lib/private.sqlite';

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (request, {RpcContext? context}) async =>
          throw StateError(_secret),
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'serverStream',
      handler: (request, {RpcContext? context}) async* {
        // Throws AFTER producing output, so the error travels on a stream that
        // has already started -- the harder path.
        yield 'first'.rpc;
        throw StateError(_secret);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'clientStream',
      handler: (requests, {RpcContext? context}) async =>
          throw StateError(_secret),
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (requests, {RpcContext? context}) async* {
        yield 'first'.rpc;
        throw StateError(_secret);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'explicit',
      handler: (request, {RpcContext? context}) async =>
          throw RpcStatusException(
            RpcStatus.permissionDenied,
            'you may not do that',
          ),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport clientTransport;
  late RpcChannelTransport serverTransport;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
    clientTransport = RpcChannelTransport(channel: clientCh, isClient: true);
    serverTransport = RpcChannelTransport(channel: serverCh, isClient: false);
    caller = RpcCallerEndpoint(transport: clientTransport);
    responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(_Contract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await clientTransport.close();
    await serverTransport.close();
  });

  /// Runs [call] and returns everything the caller was told about the failure.
  Future<String> failureText(Future<void> Function() call) async {
    try {
      await call().timeout(const Duration(seconds: 10));
      return 'NO ERROR';
    } catch (e) {
      return e.toString();
    }
  }

  void expectNoLeak(String text) {
    expect(
      text,
      isNot(contains('SECRET')),
      reason:
          'the handler exception message reached the caller; it routinely '
          'carries connection strings, SQL, paths and ids',
    );
    expect(
      text,
      isNot(contains('Bad state')),
      reason: 'even the Dart exception TYPE is a detail the peer cannot use',
    );
    expect(text, contains(kInternalErrorWireMessage));
  }

  test('unary does not leak the handler exception', () async {
    expectNoLeak(
      await failureText(
        () => caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'unary',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
      ),
    );
  });

  test('server stream does not leak the handler exception', () async {
    expectNoLeak(
      await failureText(
        () => caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'serverStream',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList(),
      ),
    );
  });

  test('client stream does not leak the handler exception', () async {
    expectNoLeak(
      await failureText(() async {
        final call = caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'clientStream',
          requestCodec: _codec,
          responseCodec: _codec,
        );
        await call(Stream.fromIterable(['a'.rpc]));
      }),
    );
  });

  test('bidirectional does not leak the handler exception', () async {
    expectNoLeak(
      await failureText(
        () => caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'bidi',
              requests: Stream.fromIterable(['a'.rpc]),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList(),
      ),
    );
  });

  test(
    'GUARD: an explicit RpcStatusException keeps its code and message',
    () async {
      // The whole point of the distinction: a handler that CHOSE to tell the
      // caller something must still be able to. Silencing this too would make
      // the fix useless -- there would be no way to report anything.
      final text = await failureText(
        () => caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'explicit',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
      );
      expect(text, contains('you may not do that'));
      expect(text, contains('${RpcStatus.permissionDenied}'));
      expect(text, isNot(contains(kInternalErrorWireMessage)));
    },
  );

  test('a bare Exception no longer reaches the caller', () async {
    // The line used to be Dart's own -- an Error is a bug, an Exception is a
    // condition someone chose to signal -- and this test pinned the second
    // half of it. That reasoning does not survive third-party libraries: a
    // database driver throws with the failing query in it, an HTTP client
    // with the URL and sometimes a token, and neither was "chosen" in any
    // sense the caller benefits from.
    //
    // `wireStatusFor` is now default-deny. The migration for a handler that
    // wanted to say something is RpcStatusException, which is pinned by the
    // guard above and by rpc_context_integration_test.
    final wire = wireStatusFor(Exception('deliberate [trace=abc123]'));
    expect(wire.status, RpcStatus.internal);
    expect(wire.message, kInternalErrorWireMessage);
    expect(wire.message, isNot(contains('abc123')));
  });

  test('GUARD: rpc_dart\'s own diagnostics still reach the caller', () async {
    // The reason an exception type is allowed through at all. These are
    // library-authored, carry no user data, and are exactly what a peer needs
    // in order to correct itself -- redacting them would make an oversized
    // message unexplainable.
    final framing = wireStatusFor(
      RpcException('gRPC frame payload is too large: 42 (max: 16)'),
    );
    expect(framing.status, RpcStatus.internal);
    expect(framing.message, contains('max: 16'));
  });

  test('GUARD: wireStatusFor forwards status details', () async {
    // Structured details ride grpc-status-details-bin and are also deliberate,
    // so they must survive the same way the message does.
    final withDetails = RpcStatusException(
      RpcStatus.invalidArgument,
      'bad field',
      details: [
        RpcBadRequest([
          RpcFieldViolation(field: 'name', description: 'must not be empty'),
        ]),
      ],
    );
    final wire = wireStatusFor(withDetails);
    expect(wire.status, RpcStatus.invalidArgument);
    expect(wire.message, 'bad field');
    expect(wire.detailsBin, isNotNull);

    final plain = wireStatusFor(StateError(_secret));
    expect(plain.status, RpcStatus.internal);
    expect(plain.message, kInternalErrorWireMessage);
    expect(plain.detailsBin, isNull);
  });
}
