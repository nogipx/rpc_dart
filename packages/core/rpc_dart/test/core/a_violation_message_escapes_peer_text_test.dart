// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A metadata violation's message quotes the peer's offending text, and the
// receiver logs that message. Raw, a CR/LF in a method path or a header name
// forged a line in the receiver's log, and its length was the peer's.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

String _violation(RpcMetadata metadata) {
  try {
    const RpcSecurityPolicy().validateMetadata(metadata);
  } on RpcMetadataViolation catch (e) {
    return e.message.toString();
  }
  return 'accepted';
}

final _control = RegExp(r'[\x00-\x1f\x7f]');

void main() {
  test('WITNESS: a method path with CR/LF is quoted escaped', () {
    final message = _violation(
      RpcMetadata([], methodPath: '/Svc\r\nFORGED LINE/m'),
    );
    expect(message, contains('Invalid methodPath'));
    expect(message, isNot(matches(_control)));
    expect(message, contains(r'\r\nFORGED LINE'));
  });

  test('WITNESS: a header name with a newline is quoted escaped', () {
    final message = _violation(RpcMetadata([RpcHeader('x-a\nforged', 'v')]));
    expect(message, contains('Invalid metadata header name'));
    expect(message, isNot(matches(_control)));
  });

  test('WITNESS: a long path is quoted to 128 characters', () {
    final message = _violation(
      RpcMetadata([], methodPath: '/${'\n' * 4000}/m'),
    );
    expect(message.length, lessThan(128 * 7 + 64));
    expect(message, endsWith('...'));
  });

  test('GUARD: a printable path is quoted as it is', () {
    final message = _violation(RpcMetadata([], methodPath: 'no-slash'));
    expect(message, 'Invalid methodPath in metadata: no-slash');
  });
}
