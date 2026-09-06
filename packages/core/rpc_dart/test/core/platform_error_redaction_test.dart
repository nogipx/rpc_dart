// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// VM only: it constructs dart:io exceptions, which dart2js cannot compile. The
// library code under test is platform-split for exactly that reason -- on web
// `isPlatformInfrastructureError` is a constant false, since none of these
// types can exist there.
@TestOn('vm')
library;

// A platform I/O exception that escapes a handler used to have its text sent to
// the caller, because `wireStatusFor` forwards any Exception on the reasoning
// that an Exception is something the thrower CHOSE to signal.
//
// That reasoning holds for an application's own exceptions and for rpc_dart's
// library diagnostics. It does not hold for dart:io's, which nobody throws
// deliberately at a caller and whose text describes the SERVER. Measured with a
// handler letting each escape, identically on http2, websocket and isolate:
//
//   before : "FileSystemException: boom, path = '/etc/private/key.pem'"
//            "SocketException: refused"
//   after  : "Internal server error"
//
// a filesystem path and a hostname, to an unauthenticated peer.
//
// The BROADER question -- whether an application's own Exception should reach
// the wire at all, which is what grpc-go refuses -- is deliberately untouched;
// it trades against deliberate reporting that works today.

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('platform I/O exceptions are redacted', () {
    test('FileSystemException does not put its path on the wire', () {
      const error = FileSystemException('boom', '/etc/private/key.pem');
      final wire = wireStatusFor(error);

      expect(wire.status, RpcStatus.internal);
      expect(wire.message, kInternalErrorWireMessage);
      expect(
        wire.message,
        isNot(contains('/etc/private')),
        reason: 'the server filesystem layout must not reach the caller',
      );
    });

    test('SocketException does not put its address on the wire', () {
      final error = SocketException(
        'refused',
        address: InternetAddress('127.0.0.1'),
        port: 5432,
      );
      final wire = wireStatusFor(error);

      expect(wire.message, kInternalErrorWireMessage);
      expect(wire.message, isNot(contains('127.0.0.1')));
      expect(wire.message, isNot(contains('5432')));
    });

    test('TLS and HTTP exceptions are redacted too', () {
      for (final error in <Object>[
        const HttpException('bad', uri: null),
        const TlsException('handshake failed'),
        const ProcessException('/usr/bin/secret-tool', ['--dump']),
      ]) {
        expect(
          wireStatusFor(error).message,
          kInternalErrorWireMessage,
          reason: '${error.runtimeType} leaked its text',
        );
      }
    });
  });

  group('GUARD: what must still reach the caller', () {
    test('an explicit RpcStatusException is forwarded intact', () {
      final wire = wireStatusFor(
        RpcStatusException(RpcStatus.permissionDenied, 'you may not do that'),
      );
      expect(wire.status, RpcStatus.permissionDenied);
      expect(wire.message, 'you may not do that');
    });

    test('a library diagnostic is still forwarded', () {
      // The reason Exceptions are forwarded at all: these are library-authored,
      // carry no user data, and are what a peer needs to correct itself.
      // Redacting them would make an oversized message unexplainable.
      final wire = wireStatusFor(
        RpcException('gRPC frame payload is too large: 100 (max: 10)'),
      );
      expect(wire.status, RpcStatus.internal);
      expect(wire.message, contains('too large'));
    });

    test('an application exception is still forwarded', () {
      // Deliberately unchanged: whether THIS should be redacted is the open
      // policy question, and silencing it here would answer it by accident.
      final wire = wireStatusFor(Exception('trace=abc123'));
      expect(wire.message, contains('trace=abc123'));
    });

    test('an Error is still redacted', () {
      expect(
        wireStatusFor(StateError('secret')).message,
        kInternalErrorWireMessage,
      );
    });
  });
}
