// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rpc_blob/rpc_blob.dart';

Future<void> main() async {
  final repository = InMemoryBlobRepository();

  try {
    print('=== InMemoryBlobRepository Example ===\n');

    final data = Uint8List.fromList(utf8.encode('Hello, World!'));
    final checksum = sha256.convert(data).toString();

    print('1. Writing blob...');
    final writeResult = await repository.writeBlob(
      BlobWriteRequest(
        collection: 'documents',
        id: 'hello.txt',
        bytes: Stream.value(data),
        contentType: 'text/plain',
        checksum: checksum,
        checksumAlgorithm: ChecksumAlgorithm.sha256,
        metadata: {'author': 'nogipx', 'tags': 'example,test'},
      ),
    );
    print('   Written: ${writeResult.descriptor.id}');
    print('   Version: ${writeResult.descriptor.version}');
    print('   Size: ${writeResult.descriptor.length} bytes');
    print('   Checksum: ${writeResult.descriptor.checksum}\n');

    print('2. Reading blob metadata...');
    final headResult = await repository.headBlob('documents', 'hello.txt');
    if (headResult != null) {
      print('   ID: ${headResult.id}');
      print('   Collection: ${headResult.collection}');
      print('   Version: ${headResult.version}');
      print('   Created: ${headResult.createdAt}');
      print('   Metadata: ${headResult.metadata}\n');
    }

    print('3. Reading blob content...');
    final readResult = await repository.readBlob(
      BlobReadRequest(collection: 'documents', id: 'hello.txt'),
    );
    if (readResult != null) {
      final content = await readResult.bytes.collectBytes();
      print('   Content: ${utf8.decode(content)}\n');
    }

    print('4. Updating blob...');
    final updatedData = Uint8List.fromList(
      utf8.encode('Hello, Updated World!'),
    );
    final updateResult = await repository.writeBlob(
      BlobWriteRequest(
        collection: 'documents',
        id: 'hello.txt',
        bytes: Stream.value(updatedData),
        expectedVersion: 1,
      ),
    );
    print('   New version: ${updateResult.descriptor.version}');
    print('   New size: ${updateResult.descriptor.length} bytes\n');

    print('5. Writing more blobs...');
    for (var i = 0; i < 5; i++) {
      await repository.writeBlob(
        BlobWriteRequest(
          collection: 'documents',
          id: 'file_$i.txt',
          bytes: Stream.value(Uint8List.fromList(utf8.encode('Content $i'))),
        ),
      );
    }
    print('   Written 5 additional blobs\n');

    print('6. Listing blobs...');
    final listResult = await repository.listBlobs(
      const ListBlobsRequest(
        collection: 'documents',
        limit: 10,
        includeMetadata: true,
      ),
    );
    print('   Found ${listResult.items.length} blobs:');
    for (final item in listResult.items) {
      print('     - ${item.id} (${item.length} bytes, v${item.version})');
    }
    print('');

    print('7. Listing collections...');
    final collections = await repository.listCollections();
    print('   Collections: ${collections.join(", ")}\n');

    print('8. Reading with range...');
    final rangeResult = await repository.readBlob(
      BlobReadRequest(
        collection: 'documents',
        id: 'hello.txt',
        rangeStart: 0,
        rangeEnd: 5,
      ),
    );
    if (rangeResult != null) {
      final rangeContent = await rangeResult.bytes.collectBytes();
      print('   Range [0:5]: ${utf8.decode(rangeContent)}\n');
    }

    print('9. Deleting blob...');
    final deleted = await repository.deleteBlob('documents', 'file_0.txt');
    print('   Deleted file_0.txt: $deleted\n');

    print('10. Deleting collection...');
    final collectionDeleted = await repository.deleteCollection('documents');
    print('   Deleted collection: $collectionDeleted\n');

    print('=== Example completed successfully ===');
  } catch (e, stackTrace) {
    print('Error: $e');
    print(stackTrace);
  } finally {
    await repository.dispose();
  }
}
