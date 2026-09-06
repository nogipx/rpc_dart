// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `wireStatusFor` is DEFAULT DENY: nothing reaches the caller unless it is
// provably safe to send.
//
// It used to forward any `Exception`, on the reasoning that an Exception is
// something the thrower CHOSE to signal, and to redact only `Error`s as bugs.
// That does not survive contact with third-party libraries -- a database driver
// throws with the failing query, an HTTP client with the URL and sometimes a
// token. Measured, identically on http2, websocket and isolate:
//
//   FileSystemException  ->  "boom, path = '/etc/private/key.pem'"
//   SocketException      ->  "refused, address = 127.0.0.1, port = 5432"
//   a custom exception   ->  "_SecretException: db-password-hunter2"
//
// An allow-list of leaky types was tried first and is the wrong shape: they
// cannot be enumerated, because most belong to packages this library has never
// heard of. Hence the inversion.
//
// VM only: it constructs dart:io exceptions, which dart2js cannot compile.
@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Stands in for a third-party library's exception -- the case an allow-list
/// of dart:io types could never have covered.
final class _DriverException implements Exception {
  _DriverException(this.detail);
  final String detail;
  @override
  String toString() => '_DriverException: $detail';
}

void main() {
  group('nothing unvetted reaches the caller', () {
    test('a third-party exception is redacted', () {
      final wire = wireStatusFor(
        _DriverException('SELECT * FROM users WHERE token = hunter2'),
      );

      expect(wire.status, RpcStatus.internal);
      expect(wire.message, kInternalErrorWireMessage);
      expect(wire.message, isNot(contains('hunter2')));
    });

    test('a bare Exception is redacted', () {
      expect(
        wireStatusFor(Exception('trace=abc123')).message,
        kInternalErrorWireMessage,
      );
    });

    test('platform I/O exceptions are redacted', () {
      final cases = <Object>[
        const FileSystemException('boom', '/etc/private/key.pem'),
        SocketException(
          'refused',
          address: InternetAddress('127.0.0.1'),
          port: 5432,
        ),
        const HttpException('bad', uri: null),
        const TlsException('handshake failed'),
        const ProcessException('/usr/bin/secret-tool', ['--dump']),
      ];
      for (final error in cases) {
        expect(
          wireStatusFor(error).message,
          kInternalErrorWireMessage,
          reason: '${error.runtimeType} leaked its text',
        );
      }
    });

    test('an Error is redacted', () {
      expect(
        wireStatusFor(StateError('secret')).message,
        kInternalErrorWireMessage,
      );
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
      // The whole reason an exception type is allowed through at all: these are
      // library-authored, carry no user data, and are what a peer needs to
      // correct itself. Redacting them makes an oversized message
      // unexplainable.
      final wire = wireStatusFor(
        RpcException('gRPC frame payload is too large: 100 (max: 10)'),
      );
      expect(wire.status, RpcStatus.internal);
      expect(wire.message, contains('too large'));
    });

    test('a frame diagnostic is forwarded', () {
      expect(
        wireStatusFor(RpcFrameException('bad frame header')).message,
        contains('bad frame header'),
      );
    });
  });
}
