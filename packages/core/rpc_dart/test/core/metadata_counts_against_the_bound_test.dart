// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 236 bounded the unlistened queue by bytes as well as by count, because
// the count alone admitted 4096 x maxMessageLengthBytes. `bufferedBytes` then
// weighed the payload only, on the rationale that metadata "is small and
// bounded by the policy's header limits" — true per frame, false in aggregate:
// maxMetadataBytes defaults to 64 KiB.
//
// Same controller, same config every transport uses; one variable, whether the
// 64 KiB sits in `payload` or in `metadata`:
//
//   payload    256 admitted    16.0 MiB    stopped by the byte bound
//   metadata  4096 admitted   256.0 MiB    stopped by the EVENT count

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _perFrame = 64 * 1024;

int _admit({required bool asMetadata}) {
  final ctl = BufferedBroadcastController<RpcTransportMessage>(
    sizeOf: (m) => m.bufferedBytes,
  );
  for (var i = 0; i < 6000; i++) {
    ctl.add(
      asMetadata
          ? RpcTransportMessage(
              streamId: 1,
              metadata: RpcMetadata([
                for (var h = 0; h < 8; h++)
                  RpcHeader('x-pad-$h', 'v' * (8 * 1024)),
              ]),
            )
          : RpcTransportMessage(streamId: 1, payload: Uint8List(_perFrame)),
    );
  }
  return ctl.pendingCount;
}

void main() {
  test('metadata-only frames are bounded by BYTES, not just by count', () {
    final admitted = _admit(asMetadata: true);
    expect(
      admitted,
      lessThan(4096),
      reason:
          'the event count stopped it, so the byte bound never applied: '
          '$admitted frames of $_perFrame bytes is '
          '${(admitted * _perFrame) ~/ (1024 * 1024)} MiB retained',
    );
  });

  test('CONTROL: payload frames were already bounded (the guard)', () {
    expect(_admit(asMetadata: false), lessThan(4096));
  });

  test('the two dimensions agree within a frame of each other', () {
    expect(
      (_admit(asMetadata: true) - _admit(asMetadata: false)).abs(),
      lessThanOrEqualTo(2),
    );
  });
}
