// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
import 'package:test/test.dart';

void main() {
  group('BlobService checksums', () {
    late SqliteBlobRepository storage;
    late BlobServiceResponder service;

    setUp(() {
      storage = SqliteBlobRepository.memory();
      service = BlobServiceResponder(storage: storage);
    });

    tearDown(() async {
      await storage.dispose();
    });

    test('fails on wrong chunk checksum', () async {
      final chunk = BlobUploadChunk(
        collection: 'c',
        blobId: '',
        offset: 0,
        bytes: Uint8List.fromList([1, 2, 3]),
        totalLength: 3,
        chunkChecksum: 'deadbeef',
        checksumAlgorithm: ChecksumAlgorithm.sha256,
        last: true,
      );

      // DATA_LOSS, not `StateError`. Round 416 replaced this library's
      // `StateError`s with typed status exceptions, and this suite is excluded
      // from `test:unit`, so the conversion never reached the assertion.
      // The status is the useful part: a corrupt chunk is not a caller mistake,
      // and `wireStatusFor` redacts a `StateError` to INTERNAL.
      await expectLater(
        service.putBlob(Stream.value(chunk)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.dataLoss,
          ),
        ),
      );
    });
  });
}
