import 'dart:typed_data';

import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
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

      await expectLater(
        service.putBlob(Stream.value(chunk)),
        throwsA(isA<StateError>()),
      );
    });
  });
}
