// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:test/test.dart';

void main() {
  late SqliteBlobRepository adapter;
  late DateTime now;
  late File dbFile;
  late Directory tmpDir;

  DateTime tick() {
    now = now.add(const Duration(milliseconds: 1));
    return now;
  }

  setUp(() {
    now = DateTime.utc(2024, 1, 1);
    tmpDir = Directory.systemTemp.createTempSync('rpc_blob_sqlite_test_');
    dbFile = File('${tmpDir.path}/blob.sqlite');
    adapter = SqliteBlobRepository.file(
      dbFile.path,
      clock: tick,
      enableWal: false,
    );
  });

  tearDown(() async {
    await adapter.dispose();
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  test('write and read roundtrip', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final checksum = sha256.convert(bytes).toString();

    final write = await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'photos',
        id: 'x1',
        bytes: Stream.value(bytes),
        contentType: 'application/octet-stream',
        length: bytes.length,
        checksum: checksum,
        metadata: const {'k': 'v'},
      ),
    );

    expect(write.descriptor.id, 'x1');
    expect(write.descriptor.collection, 'photos');
    expect(write.descriptor.length, bytes.length);
    expect(write.descriptor.version, 1);
    expect(write.descriptor.contentType, 'application/octet-stream');
    expect(write.descriptor.checksum, checksum);
    expect(write.descriptor.metadata['k'], 'v');

    final head = await adapter.headBlob('photos', 'x1');
    expect(head, isNotNull);
    expect(head!.version, 1);

    final read = await adapter.readBlob(
      BlobReadRequest(collection: 'photos', id: 'x1'),
    );
    expect(read, isNotNull);
    final readBytes = await _collect(read!.bytes);
    expect(readBytes, bytes);
    expect(read.rangeStart, isNull);
    expect(read.rangeEnd, isNull);
  });

  test('range read returns subset', () async {
    final bytes = Uint8List.fromList(List.generate(10, (i) => i));
    await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'logs',
        id: 'r1',
        bytes: Stream.value(bytes),
        length: bytes.length,
      ),
    );

    final read = await adapter.readBlob(
      BlobReadRequest(collection: 'logs', id: 'r1', rangeStart: 2, rangeEnd: 7),
    );

    expect(read, isNotNull);
    final readBytes = await _collect(read!.bytes);
    expect(readBytes, Uint8List.fromList([2, 3, 4, 5, 6]));
    expect(read.rangeStart, 2);
    expect(read.rangeEnd, 7);
  });

  test('expectedVersion enforces optimistic concurrency', () async {
    final bytes1 = Uint8List.fromList([1]);
    final bytes2 = Uint8List.fromList([2]);

    final first = await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'docs',
        id: 'd1',
        bytes: Stream.value(bytes1),
      ),
    );
    expect(first.descriptor.version, 1);

    final second = await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'docs',
        id: 'd1',
        bytes: Stream.value(bytes2),
        expectedVersion: 1,
      ),
    );
    expect(second.descriptor.version, 2);

    await expectLater(
      adapter.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'd1',
          bytes: Stream.value(bytes2),
          expectedVersion: 1,
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('delete supports optional version check', () async {
    await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'temp',
        id: 'del',
        bytes: Stream.value(Uint8List.fromList([1, 2])),
      ),
    );

    await expectLater(
      adapter.deleteBlob('temp', 'del', expectedVersion: 2),
      throwsA(isA<StateError>()),
    );

    final deleted = await adapter.deleteBlob('temp', 'del', expectedVersion: 1);
    expect(deleted, isTrue);
    final head = await adapter.headBlob('temp', 'del');
    expect(head, isNull);
  });

  test('list paginates with cursor and ordering', () async {
    Future<void> write(String id) async {
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: 'col',
          id: id,
          bytes: Stream.value(Uint8List.fromList([1])),
        ),
      );
    }

    await write('a');
    await write('b');
    await write('c');

    final page1 = await adapter.listBlobs(
      const ListBlobsRequest(collection: 'col', limit: 2),
    );
    expect(page1.items.map((e) => e.id).toList(), ['c', 'b']);
    expect(page1.nextCursor, isNotNull);

    final page2 = await adapter.listBlobs(
      ListBlobsRequest(collection: 'col', cursor: page1.nextCursor, limit: 2),
    );
    expect(page2.items.map((e) => e.id).toList(), ['a']);
    expect(page2.nextCursor, isNull);
  });

  test('list respects includeMetadata flag', () async {
    await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'meta',
        id: 'm1',
        bytes: Stream.value(Uint8List.fromList([1])),
        metadata: const {'x': 'y'},
      ),
    );

    final without = await adapter.listBlobs(
      const ListBlobsRequest(collection: 'meta', includeMetadata: false),
    );
    expect(without.items.single.metadata, isEmpty);

    final withMeta = await adapter.listBlobs(
      const ListBlobsRequest(collection: 'meta', includeMetadata: true),
    );
    expect(withMeta.items.single.metadata['x'], 'y');
  });

  test('deleteCollection drops table and registry entry', () async {
    // Seed two collections.
    await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'alpha',
        id: 'a1',
        bytes: Stream.value(Uint8List.fromList([1])),
      ),
    );
    await adapter.writeBlob(
      BlobWriteRequest(
        collection: 'beta',
        id: 'b1',
        bytes: Stream.value(Uint8List.fromList([2])),
      ),
    );

    expect(await adapter.listCollections(), containsAll(['alpha', 'beta']));

    final deleted = await adapter.deleteCollection('alpha');
    expect(deleted, isTrue);
    expect(await adapter.headBlob('alpha', 'a1'), isNull);
    expect(await adapter.listCollections(), isNot(contains('alpha')));

    // Second attempt is a no-op (returns false).
    final second = await adapter.deleteCollection('alpha');
    expect(second, isFalse);

    // Remaining collection still works.
    final headBeta = await adapter.headBlob('beta', 'b1');
    expect(headBeta, isNotNull);
  });

  test('listCollections returns created collections', () async {
    Future<void> write(String collection, String id) async {
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: collection,
          id: id,
          bytes: Stream.value(Uint8List.fromList([1])),
        ),
      );
    }

    await write('a', '1');
    await write('b', '2');

    final collections = await adapter.listCollections();
    expect(collections, containsAll(<String>['a', 'b']));
  });

  group('collectionSize', () {
    test('returns 0 for non-existent collection', () async {
      final size = await adapter.collectionSize('no_such_collection');
      expect(size, 0);
    });

    test('sums sizes of all blobs in collection', () async {
      final data1 = Uint8List.fromList([1, 2, 3]); // 3 bytes
      final data2 = Uint8List.fromList([4, 5, 6, 7]); // 4 bytes
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'a',
          bytes: Stream.value(data1),
        ),
      );
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: 'docs',
          id: 'b',
          bytes: Stream.value(data2),
        ),
      );

      final size = await adapter.collectionSize('docs');
      expect(size, 7);
    });

    test('does not include blobs from other collections', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      await adapter.writeBlob(
        BlobWriteRequest(collection: 'a', id: '1', bytes: Stream.value(data)),
      );
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: 'b',
          id: '1',
          bytes: Stream.value(Uint8List(100)),
        ),
      );

      final size = await adapter.collectionSize('a');
      expect(size, data.length);
    });

    test('returns 0 after deleteCollection', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      await adapter.writeBlob(
        BlobWriteRequest(collection: 'tmp', id: '1', bytes: Stream.value(data)),
      );
      await adapter.deleteCollection('tmp');

      final size = await adapter.collectionSize('tmp');
      expect(size, 0);
    });

    test('soft-deleted blobs are excluded', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      await adapter.writeBlob(
        BlobWriteRequest(collection: 'col', id: '1', bytes: Stream.value(data)),
      );
      await adapter.writeBlob(
        BlobWriteRequest(
          collection: 'col',
          id: '2',
          bytes: Stream.value(Uint8List(10)),
        ),
      );
      await adapter.deleteBlob('col', '2');

      final size = await adapter.collectionSize('col');
      expect(size, data.length);
    });
  });
}

Future<Uint8List> _collect(Stream<Uint8List> bytes) async {
  final builder = BytesBuilder();
  await for (final chunk in bytes) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
