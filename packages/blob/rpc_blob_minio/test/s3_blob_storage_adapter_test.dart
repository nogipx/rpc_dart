import 'dart:typed_data';

import 'package:rpc_blob_minio/rpc_blob_minio.dart';
import 'package:test/test.dart';

/// Integration test against local MinIO on localhost:9000 (http, path-style).
/// Requires existing bucket `blobs` with accessKey=minio / secretKey=minio123.
void main() {
  const endPoint = 'localhost';
  const accessKey = 'minioadmin';
  const secretKey = 'minioadmin';
  const port = 9000;
  const useSSL = false;
  const pathStyle = true;

  group('S3BlobStorageAdapter (integration)', () {
    late S3BlobRepository storage;

    setUp(() {
      storage = S3BlobRepository.connect(
        endPoint: endPoint,
        port: port,
        accessKey: accessKey,
        secretKey: secretKey,
        useSSL: useSSL,
        pathStyle: pathStyle,
      );
    });

    test('write/read text payload', () async {
      final data = Uint8List.fromList('hello minio'.codeUnits);
      final write = await storage.writeBlob(
        BlobWriteRequest(
          collection: 's3_integration',
          id: 'hello.txt',
          bytes: Stream.value(data),
          length: data.length,
          contentType: 'text/plain',
        ),
      );
      expect(write.descriptor.id, 'hello.txt');
      expect(write.descriptor.length, data.length);

      final head = await storage.headBlob('s3_integration', 'hello.txt');
      expect(head, isNotNull);
      expect(head!.length, data.length);
      expect(head.contentType, 'text/plain');

      final read = await storage.readBlob(
        BlobReadRequest(collection: 's3_integration', id: 'hello.txt'),
      );
      expect(read, isNotNull);
      final bytes = await read!.bytes.collectBytes();
      expect(bytes, data);

      final deleted = await storage.deleteBlob('s3_integration', 'hello.txt');
      expect(deleted, isTrue);
    });
  });
}
