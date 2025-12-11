import 'dart:typed_data';

import 'package:rpc_dart_blob/rpc_dart_blob.dart';
import 'package:test/test.dart';

void main() {
  group('BlobService checksums', () {
    late SqliteBlobStorageAdapter storage;
    late BlobService service;

    setUp(() {
      storage = SqliteBlobStorageAdapter.memory();
      service = BlobService(storage: storage);
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
