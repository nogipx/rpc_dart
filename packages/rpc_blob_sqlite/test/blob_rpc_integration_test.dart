import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = <_ClientFixture>[
    _ClientFixture(
      label: 'BlobRepositoryClient',
      build: () async {
        final repo = SqliteBlobRepository.memory();
        final client = IBlobClient.repository(
          repository: repo,
          disposeRepositoryOnClose: true,
        );
        return _ClientInstance(client: client, dispose: client.close);
      },
    ),
    _ClientFixture(
      label: 'BlobServiceClient (RPC in-memory)',
      build: () async {
        final repo = SqliteBlobRepository.memory();
        final env = await BlobServiceFactory.inMemory(storage: repo);
        return _ClientInstance(
          client: env.client,
          dispose: () async {
            await env.client.close();
            await env.server.close();
          },
        );
      },
    ),
  ];

  for (final fixture in fixtures) {
    group('Blob client integration [${fixture.label}]', () {
      late _ClientInstance instance;
      late IBlobClient client;
      late Directory tmpDir;

      setUp(() async {
        tmpDir = Directory.systemTemp.createTempSync('rpc_blob_rpc_test_');
        instance = await fixture.build();
        client = instance.client;
      });

      tearDown(() async {
        await instance.dispose();
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      });

      test('put/get/head/delete flow', () async {
        final bytes = Uint8List.fromList(List.generate(8, (i) => i));

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
        expect(
          _collectFrames(frames),
          Uint8List.fromList(bytes.sublist(4, 10)),
        );
        expect(frames.last.last, isTrue);
      });

      test('bulk put uploads multiple blobs', () async {
        final first = Uint8List.fromList([1, 2, 3]);
        final second = Uint8List.fromList([4, 5, 6, 7]);

        final resp = await client.bulkPutBytes(
          [
            BulkPutBlobItem(
              collection: 'rpc',
              id: 'put-a',
              bytes: Stream.value(first),
              length: first.length,
            ),
            BulkPutBlobItem(
              collection: 'rpc',
              id: 'put-b',
              bytes: Stream.value(second),
              length: second.length,
            ),
          ],
        );
        expect(resp.items.map((e) => e.id), containsAll(['put-a', 'put-b']));

        final aFrames = await client.get('rpc', 'put-a').toList();
        final bFrames = await client.get('rpc', 'put-b').toList();
        expect(_collectFrames(aFrames), first);
        expect(_collectFrames(bFrames), second);
      });

      test('bulk put attaches chunk checksums when enabled', () async {
        final clientWithChecksums = IBlobClient.repository(
          repository: SqliteBlobRepository.memory(),
          disposeRepositoryOnClose: true,
          uploadChunkBytes: 2, // force multiple chunks
          attachChunkChecksums: true,
        );
        final bytes = Uint8List.fromList([10, 11, 12, 13, 14]);

        final resp = await clientWithChecksums.bulkPutBytes(
          [
            BulkPutBlobItem(
              collection: 'rpc',
              id: 'chk',
              bytes: Stream.value(bytes),
              length: bytes.length,
            ),
          ],
        );
        expect(resp.items.single.id, 'chk');

        // Download to confirm content intact.
        final frames = await clientWithChecksums.get('rpc', 'chk').toList();
        expect(_collectFrames(frames), bytes);

        await clientWithChecksums.close();
      });

      test('bulk put fails on chunk checksum mismatch', () async {
        final clientWithChecksums = IBlobClient.repository(
          repository: SqliteBlobRepository.memory(),
          disposeRepositoryOnClose: true,
          uploadChunkBytes: 2,
          attachChunkChecksums: true,
        );

        // Manually craft two chunks, second chunk will be corrupted before send.
        final good = BlobUploadChunk(
          collection: 'rpc',
          blobId: 'bad',
          offset: 0,
          bytes: Uint8List.fromList([1, 2]),
          totalLength: 4,
          chunkChecksum: sha256.convert([1, 2]).toString(),
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          last: false,
        );
        final badBytes = Uint8List.fromList([3, 99]); // corrupted second byte
        final bad = BlobUploadChunk(
          collection: 'rpc',
          blobId: 'bad',
          offset: 2,
          bytes: badBytes,
          chunkChecksum: sha256.convert([3, 4]).toString(), // expected good bytes
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          last: true,
        );

        final stream = Stream.fromIterable([good, bad]);

        expect(
          () => clientWithChecksums.bulkPutBlob(stream),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Chunk checksum mismatch'),
          )),
        );

        await clientWithChecksums.close();
      });

      test('single put fails on chunk checksum mismatch', () async {
        final clientWithChecksums = IBlobClient.repository(
          repository: SqliteBlobRepository.memory(),
          disposeRepositoryOnClose: true,
          uploadChunkBytes: 2,
          attachChunkChecksums: true,
        );

        // First chunk carries bad checksum to trigger early failure before write.
        final badFirst = BlobUploadChunk(
          collection: 'rpc',
          blobId: 'single-bad',
          offset: 0,
          bytes: Uint8List.fromList([7, 8]),
          totalLength: 4,
          chunkChecksum: sha256.convert([7, 9]).toString(), // wrong checksum
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          last: false,
        );
        final next = BlobUploadChunk(
          collection: 'rpc',
          blobId: 'single-bad',
          offset: 2,
          bytes: Uint8List.fromList([9, 10]),
          chunkChecksum: sha256.convert([9, 10]).toString(),
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          last: true,
        );

        expect(
          () => clientWithChecksums.putBlob(Stream.fromIterable([badFirst, next])),
          throwsA(isA<StateError>()),
        );

        await clientWithChecksums.close();
      });

      test('bulk head/get/delete flow', () async {
        final first = Uint8List.fromList([1, 2, 3, 4]);
        final second = Uint8List.fromList([5, 6, 7]);

        await client.putBytes(
          collection: 'rpc',
          id: 'bulk-a',
          bytes: Stream.value(first),
          length: first.length,
        );
        await client.putBytes(
          collection: 'rpc',
          id: 'bulk-b',
          bytes: Stream.value(second),
          length: second.length,
        );

        final headResp = await client.bulkHeadBlob(
          BulkHeadBlobRequest(
            items: const [
              HeadBlobRequest(collection: 'rpc', id: 'bulk-a'),
              HeadBlobRequest(collection: 'rpc', id: 'bulk-b'),
            ],
          ),
        );
        expect(headResp.items, hasLength(2));
        expect(headResp.items.first.descriptor?.id, 'bulk-a');
        expect(headResp.items.last.descriptor?.id, 'bulk-b');

        final frames = await client
            .bulkGetBlob(
              const BulkGetBlobRequest(
                items: [
                  GetBlobRequest(collection: 'rpc', id: 'bulk-a'),
                  GetBlobRequest(collection: 'rpc', id: 'bulk-b'),
                ],
              ),
            )
            .toList();

        final grouped = _groupBulkFrames(frames);
        expect(grouped['bulk-a'], first);
        expect(grouped['bulk-b'], second);

        final deleteResp = await client.bulkDeleteBlob(
          const BulkDeleteBlobRequest(
            items: [
              DeleteBlobRequest(collection: 'rpc', id: 'bulk-a'),
              DeleteBlobRequest(collection: 'rpc', id: 'bulk-b'),
            ],
          ),
        );
        expect(deleteResp.items.map((e) => e.deleted), everyElement(isTrue));

        final headAfter = await client.bulkHeadBlob(
          const BulkHeadBlobRequest(
            items: [
              HeadBlobRequest(collection: 'rpc', id: 'bulk-a'),
              HeadBlobRequest(collection: 'rpc', id: 'bulk-b'),
            ],
          ),
        );
        expect(headAfter.items.map((e) => e.descriptor), everyElement(isNull));
      });
    });
  }
}

Uint8List _collectFrames(List<BlobDownloadFrame> frames) {
  final builder = BytesBuilder();
  for (final frame in frames) {
    builder.add(frame.bytes);
  }
  return builder.takeBytes();
}

class _ClientFixture {
  _ClientFixture({required this.label, required this.build});

  final String label;
  final Future<_ClientInstance> Function() build;
}

class _ClientInstance {
  _ClientInstance({required this.client, required this.dispose});

  final IBlobClient client;
  final Future<void> Function() dispose;
}

Map<String, Uint8List> _groupBulkFrames(List<BulkBlobDownloadFrame> frames) {
  final byId = <String, BytesBuilder>{};
  for (final frame in frames) {
    final builder = byId.putIfAbsent(frame.id, () => BytesBuilder());
    builder.add(frame.frame.bytes);
  }
  return byId.map((key, value) => MapEntry(key, value.takeBytes()));
}
