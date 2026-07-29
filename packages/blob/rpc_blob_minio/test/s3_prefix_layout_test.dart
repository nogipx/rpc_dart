// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:minio/minio.dart';
import 'package:rpc_blob_minio/rpc_blob_minio.dart';
import 'package:test/test.dart';

/// Integration tests for the single-bucket, prefix-per-collection layout.
///
/// Requires local MinIO on localhost:9010 (http, path-style)
/// with admin credentials minioadmin/minioadmin.
///
/// Run: fvm dart test test/s3_prefix_layout_test.dart
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

  /// Its own bucket, so a stray run cannot touch anything that matters.
  const testBucket = 'rpctest-blobs';

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

  Future<void> dropTestBucket() async {
    if (!await rawClient.bucketExists(testBucket)) return;
    await for (final chunk in rawClient.listObjects(
      testBucket,
      recursive: true,
    )) {
      for (final obj in chunk.objects) {
        if (obj.key != null) await rawClient.removeObject(testBucket, obj.key!);
      }
    }
    await rawClient.removeBucket(testBucket);
  }

  S3BlobRepository makeRepo({
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
          bucket: testBucket,
          immutableObjects: immutableObjects,
          createCollectionOnWrite: createCollectionOnWrite,
          publicRead: publicRead,
        ),
      );

  setUp(() async {
    if (skipReason != null) return;
    await dropTestBucket();
  });

  tearDownAll(() async {
    if (skipReason != null) return;
    await dropTestBucket();
  });

  Future<BlobWriteResult> write(
    S3BlobRepository repo,
    String collection,
    String id, [
    String body = 'x',
  ]) =>
      repo.writeBlob(
        BlobWriteRequest(
          collection: collection,
          id: id,
          bytes: Stream.value(Uint8List.fromList(body.codeUnits)),
        ),
      );

  // ---------------------------------------------------------------------------

  group('key layout', () {
    test('a blob is stored at <collection>/<id> in the one bucket', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      await write(repo, 'photos', 'a.txt', 'hello');

      final stat = await rawClient.statObject(testBucket, 'photos/a.txt');
      expect(stat.size, 5);
      expect(await rawClient.bucketExists(testBucket), isTrue);
    }, skip: skipReason);

    test('the same id in two collections stays two objects', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      await write(repo, 'left', 'same', 'one');
      await write(repo, 'right', 'same', 'twotwo');

      expect((await repo.headBlob('left', 'same'))!.length, 3);
      expect((await repo.headBlob('right', 'same'))!.length, 6);

      await repo.deleteBlob('left', 'same');
      expect(await repo.headBlob('left', 'same'), isNull);
      expect(await repo.headBlob('right', 'same'), isNotNull,
          reason: 'deleting one collection\'s copy must not touch the other');
    }, skip: skipReason);

    test('a collection containing the separator is refused', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      await expectLater(
        write(repo, 'a/b', 'x'),
        throwsA(isA<ArgumentError>()),
      );
    }, skip: skipReason);
  });

  group('collection lifecycle', () {
    test('ensureCollection creates the bucket', () async {
      if (skipReason != null) return;
      final repo = makeRepo();

      await repo.ensureCollection('declared');

      expect(await rawClient.bucketExists(testBucket), isTrue);
    }, skip: skipReason);

    test('a write to a missing bucket lands by repairing on the error',
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

      await expectLater(write(repo, 'undeclared', 'a'), throwsA(anything));
      expect(await rawClient.bucketExists(testBucket), isFalse);
    }, skip: skipReason);

    test('listCollections reports the prefixes in use', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'alpha', 'a');
      await write(repo, 'beta', 'b');
      await write(repo, 'beta', 'c');

      expect(await repo.listCollections(), ['alpha', 'beta']);
    }, skip: skipReason);

    test('deleteCollection clears one prefix and leaves the rest', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'doomed', 'a');
      await write(repo, 'doomed', 'b');
      await write(repo, 'kept', 'c');

      expect(await repo.deleteCollection('doomed'), isTrue);

      expect(await repo.headBlob('doomed', 'a'), isNull);
      expect(await repo.headBlob('kept', 'c'), isNotNull);
      expect(await repo.listCollections(), ['kept']);
      expect(await rawClient.bucketExists(testBucket), isTrue,
          reason: 'the bucket is shared — it must survive');
    }, skip: skipReason);

    test('deleteCollection on an unknown collection is false', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'real', 'a');

      expect(await repo.deleteCollection('ghost'), isFalse);
    }, skip: skipReason);
  });

  group('listBlobs', () {
    test('sees only its own collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'mine', 'a');
      await write(repo, 'mine', 'b');
      await write(repo, 'theirs', 'c');

      final listed = await repo.listBlobs(
        const ListBlobsRequest(collection: 'mine'),
      );

      expect(listed.items.map((d) => d.id), ['a', 'b']);
    }, skip: skipReason);

    test('builds descriptors from the listing, HEADs only on request',
        () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await repo.writeBlob(
        BlobWriteRequest(
          collection: 'listing',
          id: 'one.txt',
          bytes: Stream.value(Uint8List.fromList('abcdef'.codeUnits)),
          contentType: 'text/plain',
          metadata: const {'tag': 'v1'},
        ),
      );

      final cheap = await repo.listBlobs(
        const ListBlobsRequest(collection: 'listing'),
      );
      final listed = cheap.items.single;
      expect(listed.id, 'one.txt', reason: 'the prefix is stripped');
      expect(listed.length, 6, reason: 'size comes from the listing');
      expect(listed.contentType, isNull);
      expect(listed.metadata, isEmpty);

      final full = await repo.listBlobs(
        const ListBlobsRequest(collection: 'listing', includeMetadata: true),
      );
      expect(full.items.single.contentType, 'text/plain');
      expect(full.items.single.metadata['tag'], 'v1');
    }, skip: skipReason);

    test('paginates by id within the collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      for (final id in ['a', 'b', 'c']) {
        await write(repo, 'paging', id);
      }

      final first = await repo.listBlobs(
        const ListBlobsRequest(collection: 'paging', limit: 2),
      );
      expect(first.items.map((d) => d.id), ['a', 'b']);

      final second = await repo.listBlobs(
        ListBlobsRequest(
          collection: 'paging',
          limit: 2,
          cursor: first.nextCursor,
        ),
      );
      expect(second.items.map((d) => d.id), ['c']);
    }, skip: skipReason);

    test('a request prefix filters inside the collection', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'pref', 'aa');
      await write(repo, 'pref', 'ab');
      await write(repo, 'pref', 'zz');

      final listed = await repo.listBlobs(
        const ListBlobsRequest(collection: 'pref', prefix: 'a'),
      );

      expect(listed.items.map((d) => d.id), ['aa', 'ab']);
    }, skip: skipReason);
  });

  group('deleteMany', () {
    test('removes a batch within one collection only', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'batch', 'a');
      await write(repo, 'batch', 'b');
      await write(repo, 'other', 'a');

      final removed = await repo.deleteMany('batch', ['a', 'b']);

      expect(removed, unorderedEquals(['a', 'b']));
      expect(await repo.headBlob('batch', 'a'), isNull);
      expect(await repo.headBlob('other', 'a'), isNotNull);
    }, skip: skipReason);
  });

  group('collectionSize', () {
    test('is null — a prefix cannot be sized without enumerating it', () async {
      if (skipReason != null) return;
      final repo = makeRepo();
      await write(repo, 'sized', 'a', 'hello');

      expect(await repo.collectionSize('sized'), isNull);

      // The documented replacement: sum the listing, in the open.
      final listed = await repo.listBlobs(
        const ListBlobsRequest(collection: 'sized', limit: 1000),
      );
      expect(listed.items.fold<int>(0, (sum, d) => sum + d.length), 5);
    }, skip: skipReason);
  });

  group('write path', () {
    test('immutableObjects skips the read that carried the version forward',
        () async {
      if (skipReason != null) return;
      final mutable = makeRepo();
      await write(mutable, 'versions', 'a', 'one');
      expect((await write(mutable, 'versions', 'a', 'two')).descriptor.version,
          2);

      final immutable = makeRepo(immutableObjects: true);
      await write(immutable, 'hashed', 'a', 'one');
      expect((await write(immutable, 'hashed', 'a', 'one')).descriptor.version,
          1,
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
}
