// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_blob_minio/rpc_blob_minio.dart';
import 'package:test/test.dart';

/// Retry behaviour that needs no server: a port nothing listens on fails as a
/// transport error, which is the class of failure retrying exists for.
void main() {
  S3BlobRepository deadRepo({
    required int maxRetries,
    Duration? timeout,
  }) =>
      S3BlobRepository.connect(
        // Reserved-for-documentation address: connections here go nowhere
        // rather than reaching something unexpected on this machine.
        endPoint: '192.0.2.1',
        port: 9,
        accessKey: 'x',
        secretKey: 'y',
        useSSL: false,
        pathStyle: true,
        options: S3BlobStorageOptions(
          bucket: 'nope',
          maxRetries: maxRetries,
          retryBaseDelay: const Duration(milliseconds: 1),
          requestTimeout: timeout ?? const Duration(milliseconds: 120),
        ),
      );

  test('a transport failure is retried, and still surfaces in the end',
      () async {
    final repo = deadRepo(maxRetries: 2);
    final started = DateTime.now();

    await expectLater(repo.headBlob('c', 'id'), throwsA(anything));

    // Three attempts with a 1ms base and jitter: the point is that it tried
    // more than once and then gave up rather than hanging or looping.
    expect(DateTime.now().difference(started).inSeconds, lessThan(10));
    await repo.dispose();
  });

  test('maxRetries: 0 fails on the first attempt', () async {
    final repo = deadRepo(maxRetries: 0);

    await expectLater(repo.headBlob('c', 'id'), throwsA(anything));
    await repo.dispose();
  });

  test('requestTimeout bounds a call that never answers', () async {
    final repo = deadRepo(maxRetries: 0, timeout: const Duration(milliseconds: 80));
    final started = DateTime.now();

    await expectLater(
      repo.writeBlob(
        BlobWriteRequest(
          collection: 'c',
          id: 'id',
          bytes: Stream.value(Uint8List.fromList([1, 2, 3])),
        ),
      ),
      throwsA(anything),
    );

    expect(DateTime.now().difference(started).inSeconds, lessThan(10));
    await repo.dispose();
  });
}
