// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2StreamError is an ENVELOPE: HTTP/2 multiplexes many calls over one
// broadcast, so a per-stream error is wrapped with its streamId and only the
// matching subscriber should see it. Connection-level fatal errors go
// unenveloped on purpose, and that distinction is what the envelope exists for.
//
// It used to be a plain class — not an Exception at all — and `wireStatusFor`
// is DEFAULT DENY, so it took the deny branch: whatever the inner error was,
// the peer was told INTERNAL(13) "Internal server error". Round 412 had just
// finished giving every library error the status that fits; the envelope threw
// all of it away one layer out.
//
// It now derives its status THROUGH wireStatusFor rather than copying the
// inner's, which is what keeps the deny intact for a foreign inner error.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  group('the per-stream envelope', () {
    // WITNESS: every one of these was INTERNAL "Internal server error".
    test('carries the inner error\'s status', () {
      final limit = RpcHttp2StreamError(
        3,
        RpcStatusException(
          RpcStatus.resourceExhausted,
          'gRPC frame payload is too large: 40 (max: 16)',
        ),
      );
      expect(limit.statusCode, RpcStatus.resourceExhausted);
      expect(limit.message, contains('max: 16'));

      final unimplemented = RpcHttp2StreamError(
        5,
        RpcStatusException(RpcStatus.unimplemented, 'no such method'),
      );
      expect(unimplemented.statusCode, RpcStatus.unimplemented);
    });

    // WITNESS: and it is now findable by the one catch that means rpc_dart.
    test('is in the hierarchy', () {
      final e = RpcHttp2StreamError(
        3,
        RpcStatusException(RpcStatus.internal, 'x'),
      );
      expect(e, isA<RpcException>());
      expect(e, isA<RpcStatusException>());
    });

    // GUARD, and the load-bearing one: deriving the status must not become a
    // way around default-deny. A foreign error's text is internal state.
    test('redacts a foreign inner error', () {
      final foreign = RpcHttp2StreamError(
        3,
        StateError('a secret internal detail'),
      );
      expect(foreign.statusCode, RpcStatus.internal);
      expect(foreign.message, kInternalErrorWireMessage);
      expect(foreign.message, isNot(contains('secret')));
    });

    // GUARD: the envelope still holds what it was wrapping. Its whole job is
    // per-stream routing, and dropping either field would break that silently.
    test('still carries its stream id and the inner error', () {
      final inner = RpcStatusException(RpcStatus.notFound, 'gone');
      final e = RpcHttp2StreamError(7, inner);
      expect(e.streamId, 7);
      expect(identical(e.error, inner), isTrue);
    });
  });
}
