// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryBlobRepository', () {
    late InMemoryBlobRepository repository;

    setUp(() {
      repository = InMemoryBlobRepository();
    });

    tearDown(() async {
      await repository.dispose();
    });

    test('writeBlob and headBlob', () async {
      final data = Uint8List.fromList(utf8.encode('Hello, World!'));
      final checksum = sha256.convert(data).toString();

      final writeResult = await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob1',
          bytes: Stream.value(data),
          contentType: 'text/plain',
          checksum: checksum,
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          metadata: {'key': 'value'},
        ),
      );

      expect(writeResult.descriptor.id, 'blob1');
      expect(writeResult.descriptor.collection, 'test');
      expect(writeResult.descriptor.length, data.length);
      expect(writeResult.descriptor.version, 1);
      expect(writeResult.descriptor.checksum, checksum);
      expect(writeResult.descriptor.metadata, {'key': 'value'});

      final headResult = await repository.headBlob('test', 'blob1');
      expect(headResult, isNotNull);
      expect(headResult!.id, 'blob1');
      expect(headResult.version, 1);
      expect(headResult.checksum, checksum);
    });

    test('readBlob', () async {
      final data = Uint8List.fromList(utf8.encode('Test data'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob2',
          bytes: Stream.value(data),
        ),
      );

      final readResult = await repository.readBlob(
        BlobReadRequest(collection: 'test', id: 'blob2'),
      );

      expect(readResult, isNotNull);
      final readData = await readResult!.bytes.collectBytes();
      expect(readData, equals(data));
      expect(readResult.descriptor.id, 'blob2');
    });

    test('readBlob with range', () async {
      final data = Uint8List.fromList(utf8.encode('0123456789'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob3',
          bytes: Stream.value(data),
        ),
      );

      final readResult = await repository.readBlob(
        BlobReadRequest(
          collection: 'test',
          id: 'blob3',
          rangeStart: 2,
          rangeEnd: 5,
        ),
      );

      expect(readResult, isNotNull);
      final readData = await readResult!.bytes.collectBytes();
      expect(utf8.decode(readData), '234');
      expect(readResult.rangeStart, 2);
      expect(readResult.rangeEnd, 5);
    });

    test('updateBlob increments version', () async {
      final data1 = Uint8List.fromList(utf8.encode('Version 1'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob4',
          bytes: Stream.value(data1),
        ),
      );

      final data2 = Uint8List.fromList(utf8.encode('Version 2'));
      final updateResult = await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob4',
          bytes: Stream.value(data2),
        ),
      );

      expect(updateResult.descriptor.version, 2);

      final headResult = await repository.headBlob('test', 'blob4');
      expect(headResult!.version, 2);
    });

    test('expectedVersion validation on write', () async {
      final data = Uint8List.fromList(utf8.encode('Test'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob5',
          bytes: Stream.value(data),
        ),
      );

      expect(
        () => repository.writeBlob(
          BlobWriteRequest(
            collection: 'test',
            id: 'blob5',
            bytes: Stream.value(data),
            expectedVersion: 5,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('deleteBlob', () async {
      final data = Uint8List.fromList(utf8.encode('To delete'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob6',
          bytes: Stream.value(data),
        ),
      );

      final deleted = await repository.deleteBlob('test', 'blob6');
      expect(deleted, isTrue);

      final headResult = await repository.headBlob('test', 'blob6');
      expect(headResult, isNull);
    });

    test('deleteBlob with expectedVersion', () async {
      final data = Uint8List.fromList(utf8.encode('Test'));
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'blob7',
          bytes: Stream.value(data),
        ),
      );

      expect(
        () => repository.deleteBlob('test', 'blob7', expectedVersion: 5),
        throwsA(isA<StateError>()),
      );

      final deleted = await repository.deleteBlob(
        'test',
        'blob7',
        expectedVersion: 1,
      );
      expect(deleted, isTrue);
    });

    test('listBlobs with pagination', () async {
      for (var i = 0; i < 5; i++) {
        final data = Uint8List.fromList(utf8.encode('Data $i'));
        await repository.writeBlob(
          BlobWriteRequest(
            collection: 'test',
            id: 'blob$i',
            bytes: Stream.value(data),
          ),
        );
      }

      final firstPage = await repository.listBlobs(
        const ListBlobsRequest(collection: 'test', limit: 3),
      );
      expect(firstPage.items.length, 3);
      expect(firstPage.nextCursor, isNotNull);

      final secondPage = await repository.listBlobs(
        ListBlobsRequest(
          collection: 'test',
          limit: 3,
          cursor: firstPage.nextCursor,
        ),
      );
      expect(secondPage.items.length, 2);
      expect(secondPage.nextCursor, isNull);
    });

    test('listBlobs with prefix filter', () async {
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'prefix_1',
          bytes: Stream.value(Uint8List(0)),
        ),
      );
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'prefix_2',
          bytes: Stream.value(Uint8List(0)),
        ),
      );
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'test',
          id: 'other_1',
          bytes: Stream.value(Uint8List(0)),
        ),
      );

      final result = await repository.listBlobs(
        const ListBlobsRequest(collection: 'test', prefix: 'prefix_'),
      );

      expect(result.items.length, 2);
      expect(
        result.items.every((item) => item.id.startsWith('prefix_')),
        isTrue,
      );
    });

    test('listCollections', () async {
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'coll1',
          id: 'blob1',
          bytes: Stream.value(Uint8List(0)),
        ),
      );
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'coll2',
          id: 'blob2',
          bytes: Stream.value(Uint8List(0)),
        ),
      );

      final collections = await repository.listCollections();
      expect(collections, containsAll(['coll1', 'coll2']));
    });

    test('deleteCollection', () async {
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'temp',
          id: 'blob1',
          bytes: Stream.value(Uint8List(0)),
        ),
      );

      final deleted = await repository.deleteCollection('temp');
      expect(deleted, isTrue);

      final collections = await repository.listCollections();
      expect(collections, isNot(contains('temp')));
    });

    test('maxBlobBytes limit', () async {
      final smallRepo = InMemoryBlobRepository(maxBlobBytes: 10);
      final data = Uint8List(100);

      expect(
        () => smallRepo.writeBlob(
          BlobWriteRequest(
            collection: 'test',
            id: 'big',
            bytes: Stream.value(data),
          ),
        ),
        throwsA(isA<StateError>()),
      );

      await smallRepo.dispose();
    });

    test('checksum validation', () async {
      final data = Uint8List.fromList(utf8.encode('Test data'));
      final wrongChecksum = 'wrong_checksum';

      expect(
        () => repository.writeBlob(
          BlobWriteRequest(
            collection: 'test',
            id: 'blob',
            bytes: Stream.value(data),
            checksum: wrongChecksum,
            checksumAlgorithm: ChecksumAlgorithm.sha256,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('auto-generated ID', () async {
      final data = Uint8List.fromList(utf8.encode('Test'));
      final result = await repository.writeBlob(
        BlobWriteRequest(collection: 'test', bytes: Stream.value(data)),
      );

      expect(result.descriptor.id, isNotEmpty);
      expect(result.descriptor.id.length, 16);
    });

    test('throws when closed', () async {
      await repository.dispose();

      expect(
        () => repository.headBlob('test', 'blob'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
