import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_blob/rpc_dart_blob.dart';
import 'package:test/test.dart';

void main() {
  group('Blob RPC integration', () {
    late SqliteBlobStorageAdapter storage;
    late BlobServiceServer server;
    late BlobServiceClient client;
    late Directory tmpDir;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('rpc_blob_rpc_test_');
      final dbPath = '${tmpDir.path}/blobs.sqlite';
      storage = SqliteBlobStorageAdapter.file(dbPath, enableWal: false);

      final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
      clientTransport = callerTransport;
      serverTransport = responderTransport;
      server = BlobServiceFactory.createServer(
        transport: serverTransport,
        storage: storage,
      );
      await server.start();
      client = BlobServiceFactory.createClient(transport: clientTransport);
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('put/get/head/delete flow over RPC', () async {
      final bytes = Uint8List.fromList(List.generate(8, (i) => i));

      // Upload in two chunks.
      final upload = client.putBytes(
        collection: 'rpc',
        id: 'rpc-id',
        bytes: Stream.value(bytes),
        length: bytes.length,
        contentType: 'application/octet-stream',
        metadata: const {'m': '1'},
      );

      final putResp = await upload;
      expect(putResp.descriptor.id, 'rpc-id');
      expect(putResp.descriptor.length, bytes.length);

      final head = await client.head('rpc', 'rpc-id');
      expect(head.descriptor, isNotNull);
      expect(head.descriptor!.length, bytes.length);

      // Download and reassemble bytes.
      final downloadFrames = await client.get('rpc', 'rpc-id').toList();
      final downloaded = _collectFrames(downloadFrames);
      expect(downloaded, bytes);
      expect(
        downloadFrames.first.descriptor?.id,
        'rpc-id',
        reason: 'Descriptor should be present on first frame',
      );

      final delResp = await client.delete('rpc', 'rpc-id');
      expect(delResp.deleted, isTrue);

      final missingHead = await client.head('rpc', 'rpc-id');
      expect(missingHead.descriptor, isNull);

      final collections = await client.listCollections();
      expect(collections.collections, contains('rpc'));
    });

    test('range get returns offsets and range metadata', () async {
      final bytes = Uint8List.fromList(List.generate(16, (i) => i + 1));
      await client.putBytes(
        collection: 'rpc',
        id: 'range-id',
        bytes: Stream.value(bytes),
        length: bytes.length,
      );

      final frames = await client
          .get('rpc', 'range-id', rangeStart: 4, rangeEnd: 10)
          .toList();

      expect(frames, isNotEmpty);
      expect(frames.first.rangeStart, 4);
      expect(frames.first.rangeEnd, 10);
      expect(frames.first.offset, 4);
      expect(frames.first.descriptor?.id, 'range-id');
      expect(_collectFrames(frames), Uint8List.fromList(bytes.sublist(4, 10)));
      expect(frames.last.last, isTrue);
    });
  });
}

Uint8List _collectFrames(List<BlobDownloadFrame> frames) {
  final builder = BytesBuilder();
  for (final frame in frames) {
    builder.add(frame.bytes);
  }
  return builder.takeBytes();
}
