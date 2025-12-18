import 'package:minio/minio.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_blob/rpc_dart_blob.dart';
import 'package:test/test.dart';

/// RPC-level integration over S3/MinIO backend.
/// Requires local MinIO on localhost:9000 (http, path-style) with bucket `blobs`
/// and credentials minio/minio123 already present.
void main() {
  const endPoint = 'localhost';
  const bucket = 'blobs';
  const accessKey = 'minioadmin';
  const secretKey = 'minioadmin';
  const port = 9004;
  const useSSL = false;
  const pathStyle = true;

  String? skipReason;

  setUpAll(() async {
    final client = Minio(
      endPoint: endPoint,
      port: port,
      accessKey: accessKey,
      secretKey: secretKey,
      useSSL: useSSL,
      pathStyle: pathStyle,
    );
    try {
      final exists = await client.bucketExists(bucket);
      if (!exists) {
        skipReason = 'Bucket "$bucket" is missing on $endPoint:$port';
      }
    } catch (e) {
      skipReason = 'MinIO not reachable: $e';
    }
  });

  group('Blob RPC over S3', () {
    late S3BlobStorageAdapter storage;
    late BlobServiceServer server;
    late BlobServiceClient client;
    late IRpcTransport caller;
    late IRpcTransport responder;

    setUp(() async {
      if (skipReason != null) {
        return;
      }
      storage = S3BlobStorageAdapter.connect(
        bucket: bucket,
        endPoint: endPoint,
        port: port,
        accessKey: accessKey,
        secretKey: secretKey,
        useSSL: useSSL,
        pathStyle: pathStyle,
      );
      final pair = RpcInMemoryTransport.pair();
      caller = pair.$1;
      responder = pair.$2;
      server = BlobServiceFactory.createServer(
        transport: responder,
        storage: storage,
      );
      await server.start();
      client = BlobServiceFactory.createClient(transport: caller);
    });

    tearDown(() async {
      if (skipReason != null) return;
      await client.close();
      await server.close();
    });

    test('put/get/head/delete with presigned url', () async {
      if (skipReason != null) {
        return;
      }
      final data = Uint8List.fromList('rpc over s3'.codeUnits);
      final resp = await client.putBytes(
        collection: 'rpc_s3',
        id: 'hello.txt',
        bytes: Stream.value(data),
        length: data.length,
        contentType: 'text/plain',
      );
      expect(resp.descriptor.length, data.length);
      expect(resp.descriptor.downloadUrl, isNotNull);

      final head = await client.head('rpc_s3', 'hello.txt');
      expect(head.descriptor, isNotNull);
      expect(head.descriptor!.downloadUrl, isNotNull);

      final frames = await client.get('rpc_s3', 'hello.txt').toList();
      final collected = await Stream.fromIterable(
        frames.map((f) => f.bytes),
      ).asyncExpand((bytes) => Stream.value(bytes)).collectBytes();
      expect(collected, data);
      expect(frames.first.descriptor?.downloadUrl, isNotNull);

      final deleted = await client.delete('rpc_s3', 'hello.txt');
      expect(deleted.deleted, isTrue);
    }, skip: skipReason);
  });
}
