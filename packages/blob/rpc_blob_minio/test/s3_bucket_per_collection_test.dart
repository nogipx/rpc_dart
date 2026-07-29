// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:minio/minio.dart';
import 'package:rpc_blob_minio/rpc_blob_minio.dart';
import 'package:test/test.dart';

/// Integration tests for the bucket-per-collection model.
///
/// Requires local MinIO on localhost:9010 (http, path-style)
/// with admin credentials minioadmin/minioadmin.
///
/// Run: fvm dart test test/s3_bucket_per_collection_test.dart
void main() {
  const endPoint = 'localhost';
  const accessKey = 'minioadmin';
  const secretKey = 'minioadmin';
  // 9010, not the MinIO default: these tests create and drop buckets, and 9000
  // is commonly a port-forward to a real deployment. Run a throwaway server
  // there, e.g. `docker run --rm -p 9010:9000 quay.io/minio/minio server /data`.
  const port = 9010;
  const useSSL = false;
  const pathStyle = true;

  /// Prefix used by all test buckets — makes cleanup reliable and avoids
  /// colliding with real data.
  const testBucketPrefix = 'rpctest-';

  String? skipReason;
  late Minio rawClient;

  setUpAll(() async {
    rawClient = Minio(
      endPoint: endPoint,
      port: port,
      accessKey: accessKey,
      secretKey: secretKey,
      useSSL: useSSL,
      pathStyle: pathStyle,
    );
    try {
      await rawClient.listBuckets();
    } catch (e) {
      skipReason = 'MinIO not reachable at $endPoint:$port — $e';
    }
  });

  /// Deletes all buckets whose names start with [testBucketPrefix].
  Future<void> cleanupTestBuckets() async {
    final buckets = await rawClient.listBuckets();
    for (final b in buckets) {
      if (!b.name.startsWith(testBucketPrefix)) continue;
      // Remove all objects first.
      await for (final chunk in rawClient.listObjects(
        b.name,
        recursive: true,
      )) {
        for (final obj in chunk.objects) {
          if (obj.key != null) await rawClient.removeObject(b.name, obj.key!);
        }
      }
      await rawClient.removeBucket(b.name);
    }
  }

  S3BlobRepository makeRepo({
    bool useAdminApi = true,
    bool immutableObjects = false,
    bool createCollectionOnWrite = true,
    bool? publicRead,
  }) =>
      S3BlobRepository.connect(
        endPoint: endPoint,
        port: port,
        accessKey: accessKey,
        secretKey: secretKey,
        useSSL: useSSL,
        pathStyle: pathStyle,
        options: S3BlobStorageOptions(
          bucketPrefix: testBucketPrefix,
          useAdminApi: useAdminApi,
          immutableObjects: immutableObjects,
          createCollectionOnWrite: createCollectionOnWrite,
          publicRead: publicRead,
        ),
      );

  setUp(() async {
    if (skipReason != null) return;
    await cleanupTestBuckets();
  });

  tearDown(() async {
    if (skipReason != null) return;
    await cleanupTestBuckets();
  });

  // ---------------------------------------------------------------------------

  group('bucket auto-creation', () {
    test('bucket is created on first writeBlob', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList('hello'.codeUnits);

      expect(
        await rawClient.bucketExists('${testBucketPrefix}photos'),
        isFalse,
      );

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'photos',
          id: 'a.txt',
          bytes: Stream.value(data),
        ),
      );

      expect(await rawClient.bucketExists('${testBucketPrefix}photos'), isTrue);
    }, skip: skipReason);

    test('bucket is not created on read of missing collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      final result = await repo.headBlob('ghost', 'x');
      expect(result, isNull);
      expect(await rawClient.bucketExists('${testBucketPrefix}ghost'), isFalse);
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------

  group('bucket name normalisation', () {
    test('uppercase collection maps to lowercase bucket', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList([1]);

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'MyPhotos',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );

      expect(
        await rawClient.bucketExists('${testBucketPrefix}myphotos'),
        isTrue,
      );
    }, skip: skipReason);

    test('special characters in collection name become hyphens', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList([1]);

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'user_data/2024',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );

      expect(
        await rawClient.bucketExists('${testBucketPrefix}user-data-2024'),
        isTrue,
      );
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------

  group('write / read / delete', () {
    test('roundtrip', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList('hello minio bucket model'.codeUnits);

      final write = await repo.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'hello.txt',
          bytes: Stream.value(data),
          contentType: 'text/plain',
        ),
      );
      expect(write.descriptor.id, 'hello.txt');
      expect(write.descriptor.length, data.length);
      expect(write.descriptor.version, 1);

      final head = await repo.headBlob('docs', 'hello.txt');
      expect(head, isNotNull);
      expect(head!.length, data.length);
      expect(head.contentType, 'text/plain');

      final read = await repo.readBlob(
        BlobReadRequest(collection: 'docs', id: 'hello.txt'),
      );
      expect(read, isNotNull);
      final bytes = await read!.bytes.collectBytes();
      expect(bytes, data);

      final deleted = await repo.deleteBlob('docs', 'hello.txt');
      expect(deleted, isTrue);

      expect(await repo.headBlob('docs', 'hello.txt'), isNull);
    }, skip: skipReason);

    test('deleteBlob returns false for missing blob', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final result = await repo.deleteBlob('docs', 'nonexistent');
      expect(result, isFalse);
    }, skip: skipReason);

    test('version increments on overwrite', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList([1, 2, 3]);

      final v1 = await repo.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'f',
          bytes: Stream.value(data),
        ),
      );
      expect(v1.descriptor.version, 1);

      final v2 = await repo.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'f',
          bytes: Stream.value(data),
        ),
      );
      expect(v2.descriptor.version, 2);
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------

  group('listCollections', () {
    test('returns created collections filtered by prefix', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList([1]);

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'alpha',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );
      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'beta',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );

      final collections = await repo.listCollections();
      expect(collections, containsAll(['alpha', 'beta']));
    }, skip: skipReason);

    test('does not include buckets without the prefix', () async {
      if (skipReason != null) return;
      // Create a bucket outside the test prefix.
      await rawClient.makeBucket('outsider-bucket');
      addTearDown(() async {
        try {
          await rawClient.removeBucket('outsider-bucket');
        } catch (_) {}
      });

      final repo = makeRepo();
      final collections = await repo.listCollections();
      expect(collections, isNot(contains('outsider-bucket')));
      expect(collections, isNot(contains('outsider')));
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------

  group('deleteCollection', () {
    test('removes bucket and all objects', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList([1, 2, 3]);

      await repo.writeBlob(
        BlobWriteRequest(collection: 'tmp', id: 'a', bytes: Stream.value(data)),
      );
      await repo.writeBlob(
        BlobWriteRequest(collection: 'tmp', id: 'b', bytes: Stream.value(data)),
      );
      expect(await rawClient.bucketExists('${testBucketPrefix}tmp'), isTrue);

      final deleted = await repo.deleteCollection('tmp');
      expect(deleted, isTrue);
      expect(await rawClient.bucketExists('${testBucketPrefix}tmp'), isFalse);
    }, skip: skipReason);

    test('returns false for non-existent collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      expect(await repo.deleteCollection('ghost'), isFalse);
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------

  group('write path', () {
    Future<BlobWriteResult> write(
      S3BlobRepository repo,
      String collection,
      String id,
      String body,
    ) =>
        repo.writeBlob(
          BlobWriteRequest(
            collection: collection,
            id: id,
            bytes: Stream.value(Uint8List.fromList(body.codeUnits)),
          ),
        );

    test('ensureCollection creates the bucket up front', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      await repo.ensureCollection('declared');

      expect(
        await rawClient.bucketExists('${testBucketPrefix}declared'),
        isTrue,
      );
    }, skip: skipReason);

    test('a write to a missing bucket still lands, by repairing on the error',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      final result = await write(repo, 'repaired', 'a', 'hello');

      expect(result.descriptor.length, 5);
      expect(await repo.headBlob('repaired', 'a'), isNotNull);
    }, skip: skipReason);

    test('createCollectionOnWrite: false refuses instead of creating',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo(createCollectionOnWrite: false);

      await expectLater(
        write(repo, 'undeclared', 'a', 'hello'),
        throwsA(anything),
      );
      expect(
        await rawClient.bucketExists('${testBucketPrefix}undeclared'),
        isFalse,
      );
    }, skip: skipReason);

    test('immutableObjects skips the read that carried the version forward',
        () async {
      if (skipReason != null) return;
      final mutable = makeRepo();
      await write(mutable, 'versions', 'a', 'one');
      final second = await write(mutable, 'versions', 'a', 'two');
      expect(second.descriptor.version, 2,
          reason: 'default behaviour still reads and increments');

      final immutable = makeRepo(immutableObjects: true);
      await write(immutable, 'hashed', 'a', 'one');
      final rewrite = await write(immutable, 'hashed', 'a', 'one');
      expect(rewrite.descriptor.version, 1,
          reason: 'no read, so nothing to increment — the id is the content');
    }, skip: skipReason);

    test('an explicit expectedVersion still reads, even when immutable',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo(immutableObjects: true);
      await write(repo, 'guarded', 'a', 'one');

      await expectLater(
        repo.writeBlob(
          BlobWriteRequest(
            collection: 'guarded',
            id: 'a',
            bytes: Stream.value(Uint8List.fromList('two'.codeUnits)),
            expectedVersion: 99,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    }, skip: skipReason);

    test('publicRead: false presigns without asking for the bucket policy',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo(publicRead: false);

      final result = await write(repo, 'urls', 'a', 'hello');

      expect(result.descriptor.downloadUrl, contains('X-Amz-Signature'));
    }, skip: skipReason);
  });

  group('listBlobs', () {
    test('lists from the listing itself, and only fetches metadata on request',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final data = Uint8List.fromList('abcdef'.codeUnits);
      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'listing',
          id: 'one.txt',
          bytes: Stream.value(data),
          contentType: 'text/plain',
          metadata: const {'tag': 'v1'},
        ),
      );

      // Cheap path: whatever S3 returns for a listing — no HEAD per object.
      final cheap = await repo.listBlobs(
        const ListBlobsRequest(collection: 'listing'),
      );
      expect(cheap.items, hasLength(1));
      final listed = cheap.items.single;
      expect(listed.id, 'one.txt');
      expect(listed.length, data.length, reason: 'size comes from the listing');
      expect(listed.updatedAt, isNotNull);
      expect(listed.contentType, isNull,
          reason: 'content type lives in object metadata, which was not read');
      expect(listed.metadata, isEmpty);

      // Explicit ask: the caller pays a HEAD per object and gets everything.
      final full = await repo.listBlobs(
        const ListBlobsRequest(collection: 'listing', includeMetadata: true),
      );
      final detailed = full.items.single;
      expect(detailed.length, data.length);
      expect(detailed.contentType, 'text/plain');
      expect(detailed.metadata['tag'], 'v1');
    }, skip: skipReason);

    test('paginates without metadata', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      for (final id in ['a', 'b', 'c']) {
        await repo.writeBlob(
          BlobWriteRequest(
            collection: 'paging',
            id: id,
            bytes: Stream.value(Uint8List.fromList([1])),
          ),
        );
      }

      final first = await repo.listBlobs(
        const ListBlobsRequest(collection: 'paging', limit: 2),
      );
      expect(first.items.map((d) => d.id), ['a', 'b']);
      expect(first.nextCursor, isNotNull);

      final second = await repo.listBlobs(
        ListBlobsRequest(
          collection: 'paging',
          limit: 2,
          cursor: first.nextCursor,
        ),
      );
      expect(second.items.map((d) => d.id), ['c']);
    }, skip: skipReason);
  });

  group('collectionSize', () {
    /// Prints the size of every test bucket visible to [rawClient].
    Future<void> printAllBucketSizes(S3BlobRepository repo) async {
      final collections = await repo.listCollections();
      for (final c in collections) {
        final size = await repo.collectionSize(c);
        // ignore: avoid_print
        print('  bucket "$testBucketPrefix$c" → $size bytes');
      }
    }

    test('returns 0 for non-existent collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      final size = await repo.collectionSize('no_such_collection');
      // ignore: avoid_print
      print('  bucket "${testBucketPrefix}no_such_collection" → $size bytes');
      expect(size, 0);
    }, skip: skipReason);

    test(
      'listObjects fallback (useAdminApi: false) returns correct size',
      () async {
        if (skipReason != null) return;
        final repo = makeRepo(useAdminApi: false);
        final data1 = Uint8List.fromList([1, 2, 3]); // 3 bytes
        final data2 = Uint8List.fromList([4, 5, 6, 7, 8]); // 5 bytes

        await repo.writeBlob(
          BlobWriteRequest(
            collection: 'sizing',
            id: 'a',
            bytes: Stream.value(data1),
          ),
        );
        await repo.writeBlob(
          BlobWriteRequest(
            collection: 'sizing',
            id: 'b',
            bytes: Stream.value(data2),
          ),
        );

        await printAllBucketSizes(repo);

        final size = await repo.collectionSize('sizing');
        expect(size, data1.length + data2.length);
      },
      skip: skipReason,
    );

    test('admin API (useAdminApi: true) returns non-negative size', () async {
      if (skipReason != null) return;
      final repo = makeRepo(useAdminApi: true);
      final data = Uint8List.fromList(List.filled(100, 0));

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'adminsize',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );

      await printAllBucketSizes(repo);

      // MinIO updates usage stats asynchronously so we only assert non-negative.
      final size = await repo.collectionSize('adminsize');
      expect(size, greaterThanOrEqualTo(0));
    }, skip: skipReason);

    test('returns 0 after deleteCollection', () async {
      if (skipReason != null) return;
      final repo = makeRepo(useAdminApi: false);
      final data = Uint8List.fromList([1, 2, 3]);

      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'gone',
          id: 'x',
          bytes: Stream.value(data),
        ),
      );

      // ignore: avoid_print
      print('  before delete:');
      await printAllBucketSizes(repo);

      await repo.deleteCollection('gone');

      final size = await repo.collectionSize('gone');
      // ignore: avoid_print
      print('  after delete: bucket "${testBucketPrefix}gone" → $size bytes');
      expect(size, 0);
    }, skip: skipReason);
  });
}
