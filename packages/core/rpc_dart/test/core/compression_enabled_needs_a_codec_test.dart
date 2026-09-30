// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `compressionEnabled: true` declared `grpc-encoding: gzip` from a CONSTANT while
// the very next line built `grpc-accept-encoding` from the REGISTRY. Where no gzip
// codec is registered the two disagreed: the caller announced an encoding it could
// not perform, the peer refused it, and EVERY call failed.
//
// dart2js is exactly that state by construction — the built-in gzip is backed by
// dart:io — so `compressionEnabled: true` made the library unusable there. The
// registry is the knob, not the platform, which is why this runs everywhere.
//
//   registry                         compressionEnabled: true
//   as shipped (identity,gzip)       echoed 64 bytes
//   gzip UNREGISTERED (identity)     RpcStatusException(12): Unsupported grpc-encoding
//   a registered codec               echoed 64 bytes
//   CONTROL compression off          echoed 64 bytes
//
// The measurements are in `.claude/loop/rounds/543`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => req,
    );
  }
}

/// Shrinks repeated bytes, so "a codec was used" is observable without depending
/// on any platform having gzip. Deliberately not a general compressor: the only
/// payload sent through it here is one long run.
final class _RunLength implements RpcCompressionCodec {
  const _RunLength();

  @override
  Uint8List compress(Uint8List data) {
    final out = <int>[];
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      var run = 1;
      while (i + run < data.length && data[i + run] == b && run < 255) {
        run++;
      }
      out
        ..add(run)
        ..add(b);
      i += run;
    }
    return Uint8List.fromList(out);
  }

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) {
    final out = <int>[];
    for (var i = 0; i + 1 < data.length; i += 2) {
      out.addAll(List<int>.filled(data[i], data[i + 1]));
    }
    return Uint8List.fromList(out);
  }
}

typedef _Run = ({String outcome, String? declared});

/// One unary call over a BYTE pipe, reporting what came back and what encoding the
/// request declared.
///
/// A byte pipe and not `memoryPair`: the encoding header is only added when
/// `!transport.supportsZeroCopy`, so a zero-copy pair skips the path entirely.
Future<_Run> _call({required bool compressionEnabled}) async {
  final (clientTransport, serverTransport) = RpcChannelTransport.pair();
  String? declared;
  final sub = serverTransport.incomingMessages.listen((m) {
    declared ??= m.metadata?.getHeaderValue(RpcHeaders.grpcEncoding);
  });
  final caller = RpcCallerEndpoint(
    transport: clientTransport,
    compressionEnabled: compressionEnabled,
  );
  final responder = RpcResponderEndpoint(transport: serverTransport)
    ..registerServiceContract(_Echo())
    ..start();
  try {
    final reply = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'echo',
          request: ('a' * 64).rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return (
      outcome: reply.value == 'a' * 64 ? 'echoed' : 'wrong payload',
      declared: declared,
    );
  } on TimeoutException {
    return (outcome: 'TIMEOUT', declared: declared);
  } catch (e) {
    return (outcome: '$e', declared: declared);
  } finally {
    await sub.cancel();
    await caller.close();
    await responder.close();
  }
}

// The registry is static state and the built-in codec cannot be re-registered from
// outside — it is private, and the public `register` takes an instance. So nothing
// here restores it: each test builds the registry state it needs outright, and the
// state it leaves is confined to this suite, because `dart test` gives every test
// FILE its own isolate.
//
// Which also means the shipped state differs by platform at the top of this file —
// gzip on the VM, nothing on dart2js — and no test may assume either.
void main() {
  test(
    'WITNESS a call still works when no codec is registered',
    () async {
      RpcGrpcCompression.unregister(RpcGrpcCompression.gzip);
      expect(
        RpcGrpcCompression.isSupported(RpcGrpcCompression.gzip),
        isFalse,
        reason: 'the premise: this is dart2js\'s shipped state',
      );

      final r = await _call(compressionEnabled: true);

      expect(
        r.outcome,
        'echoed',
        reason:
            'the caller declared gzip from a constant, so the peer refused an '
            'encoding neither side had',
      );
      expect(
        r.declared,
        isNull,
        reason: 'nothing can be performed, so nothing may be announced',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD a registered codec IS announced and used',
    () async {
      // Without this the fix could pass by never compressing anything.
      RpcGrpcCompression.unregister(RpcGrpcCompression.gzip);
      RpcGrpcCompression.register('x-runlength', const _RunLength());
      addTearDown(() => RpcGrpcCompression.unregister('x-runlength'));

      final r = await _call(compressionEnabled: true);

      expect(r.outcome, 'echoed');
      expect(r.declared, 'x-runlength');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD gzip is still preferred when it is there',
    () async {
      // The shipped default must not change for anyone who has gzip.
      if (!RpcGrpcCompression.isSupported(RpcGrpcCompression.gzip)) {
        RpcGrpcCompression.register('gzip', const _RunLength());
      }
      RpcGrpcCompression.register('x-runlength', const _RunLength());
      addTearDown(() => RpcGrpcCompression.unregister('x-runlength'));

      final r = await _call(compressionEnabled: true);

      expect(r.outcome, 'echoed');
      expect(
        r.declared,
        'gzip',
        reason: 'gzip is preferred over any other registered encoding',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'CONTROL compression off works in either registry state',
    () async {
      expect((await _call(compressionEnabled: false)).outcome, 'echoed');
      RpcGrpcCompression.unregister(RpcGrpcCompression.gzip);
      expect((await _call(compressionEnabled: false)).outcome, 'echoed');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
