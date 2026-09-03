// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every RpcMessageParser in the stream layer was built without any limits, so
// it fell back to RpcMessageParser's own defaults -- a hard-coded 64MB message
// ceiling -- and RpcSecurityPolicy.maxMessageLengthBytes was not enforced on
// that path at all.
//
// Invisible while payloads are uncompressed: the channel bounds the frame by
// the same policy before the parser sees it. NOT invisible once a payload is
// compressed, because the channel bounds the COMPRESSED bytes and the
// expansion was bounded only by that 64MB default.
//
// Measured end to end against a server configured maxMessageLengthBytes: 1MB,
// sending the same highly compressible payload both ways:
//
//   32MB uncompressed -> rejected (the policy works)
//   32MB compressed   -> ACCEPTED, 32x the configured limit
//   60MB compressed   -> ACCEPTED, 60x the configured limit
//   70MB compressed   -> rejected at "max: 67108864" -- the 64MB default,
//                        not the 1MB the operator asked for
//
// Wrong in BOTH directions: a policy tighter than 64MB was not enforced, and a
// policy looser than 64MB was silently capped at 64MB.
//
// IRpcSecurityPolicyAware exists for this, and the responder pipeline already
// reads maxActiveStreams and halfOpenStreamTimeout through it. The parsers just
// never asked.
//
// This test uses a synthetic run-length codec rather than real gzip: core's
// gzip is dart:io-only, and the defect is platform-independent, so a codec that
// works on dart2js as well keeps the regression on the web target too.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _encoding = 'rle-test';
const _mb = 1024 * 1024;

/// Lossless run-length codec: `[count:uint16][byte]` pairs.
///
/// Gives a large, predictable expansion ratio without depending on dart:io, so
/// a tiny frame on the wire becomes an arbitrarily large decoded message --
/// which is the whole point of the limit under test.
final class _RunLengthCodec implements RpcCompressionCodec {
  const _RunLengthCodec();

  @override
  Uint8List compress(Uint8List data) {
    final out = BytesBuilder();
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      var run = 1;
      while (i + run < data.length && data[i + run] == b && run < 0xFFFF) {
        run++;
      }
      out.addByte(run & 0xFF);
      out.addByte((run >> 8) & 0xFF);
      out.addByte(b);
      i += run;
    }
    return out.toBytes();
  }

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) {
    // Size the output first, so the bound is checked BEFORE materializing it --
    // the behaviour the real gzip codec implements with a chunked sink.
    var total = 0;
    for (var i = 0; i + 2 < data.length; i += 3) {
      total += data[i] | (data[i + 1] << 8);
    }
    if (maxOutputBytes != null && total > maxOutputBytes) {
      throw FormatException(
        'Decompressed payload exceeds limit: $total bytes '
        '(max: $maxOutputBytes)',
      );
    }
    final out = Uint8List(total);
    var o = 0;
    for (var i = 0; i + 2 < data.length; i += 3) {
      final run = data[i] | (data[i + 1] << 8);
      out.fillRange(o, o + run, data[i + 2]);
      o += run;
    }
    return out;
  }
}

final _codec = RpcCodec(RpcString.fromJson);

int? _received;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'sink',
      handler: (request, {RpcContext? context}) async {
        _received = request.value.length;
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends a highly compressible payload of [payloadChars] to a server whose
/// policy caps a decoded message at [policyLimitBytes]. Returns the length the
/// handler saw, or null with the failure.
Future<({int? delivered, Object? error})> _send({
  required int policyLimitBytes,
  required int payloadChars,
  required bool compress,
}) async {
  _received = null;

  final policy = RpcSecurityPolicy(maxMessageLengthBytes: policyLimitBytes);
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(policy: policy);
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: policy,
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: policy,
  );
  // compressionEnabled hardcodes gzip, and the pipeline only injects it when
  // the context carries no grpc-encoding of its own -- so selecting the codec
  // through the context is how a non-gzip encoding is chosen.
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  responder.start();

  Object? error;
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'sink',
          request: (' ' * payloadChars).rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withHeaders({
            RpcHeaders.grpcEncoding: compress
                ? _encoding
                : RpcGrpcCompression.identity,
            RpcHeaders.grpcAcceptEncoding: RpcGrpcCompression.identity,
          }),
        )
        .timeout(const Duration(seconds: 30));
  } catch (e) {
    error = e;
  }

  final delivered = _received;
  await caller.close();
  await responder.close();
  return (delivered: delivered, error: error);
}

void main() {
  setUpAll(
    () => RpcGrpcCompression.register(_encoding, const _RunLengthCodec()),
  );

  group('a compressed payload is bounded by the configured policy', () {
    // WITNESS: the security-relevant direction. Pre-fix this was delivered in
    // full, 32x the limit the operator set.
    test('a policy TIGHTER than the parser default is enforced', () async {
      final r = await _send(
        policyLimitBytes: 1 * _mb,
        payloadChars: 32 * _mb,
        compress: true,
      );

      expect(
        r.delivered,
        isNull,
        reason:
            'a ${(r.delivered ?? 0) ~/ _mb}MB message was delivered to a '
            'handler on a server configured for 1MB -- the compressed path '
            'ignores maxMessageLengthBytes',
      );
      expect(
        r.error.toString(),
        contains('max: ${1 * _mb}'),
        reason:
            'rejected, but against the wrong limit: the message should name '
            'the configured ${1 * _mb} bytes, not the parser default',
      );
    });

    // WITNESS: the other direction. Pre-fix an operator who RAISED the limit
    // was still capped at the parser's 64MB default.
    test('a policy LOOSER than the parser default is honoured', () async {
      final r = await _send(
        policyLimitBytes: 128 * _mb,
        payloadChars: 70 * _mb,
        compress: true,
      );

      expect(
        r.delivered,
        70 * _mb,
        reason:
            'a 70MB message was refused by a server configured for 128MB: '
            '${r.error}',
      );
    });
  });

  group('the surrounding behaviour is unchanged', () {
    // GUARD: the uncompressed path was always bounded, by the channel.
    test('an oversized UNCOMPRESSED payload is still refused', () async {
      final r = await _send(
        policyLimitBytes: 1 * _mb,
        payloadChars: 32 * _mb,
        compress: false,
      );
      expect(r.delivered, isNull);
    });

    // GUARD: ordinary compressed traffic under the limit must still work, or
    // the fix would just be a new outage.
    test('compressed traffic within the limit still round-trips', () async {
      final r = await _send(
        policyLimitBytes: 16 * _mb,
        payloadChars: 4 * _mb,
        compress: true,
      );
      expect(r.delivered, 4 * _mb, reason: '${r.error}');
    });
  });
}
