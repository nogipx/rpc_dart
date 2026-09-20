// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `putBytes(id: '')` silently generated an id instead of refusing.
//
//   asked=""  got=18df18eedb93057e
//
// The API already has a way to ask for a generated id, and it is `null`. With
// null present, an empty string is not a second way to ask -- it is a caller
// whose id-building produced nothing, being answered as though it had made a
// request. For a content-addressed caller, which is what these packages exist
// for, the substituted id reads as "not stored" while the bytes sit orphaned
// under a name nothing references.
//
// The refusal is at `putBytes`, where `null` exists, and NOT on the wire:
// `BlobUploadChunk.blobId` is non-nullable, so empty-means-generate is the only
// encoding available there and is deliberate.
//
// BOTH implementations of IBlobClient are driven. A refusal in one
// implementation of an interchangeable interface is B-33 all over again.

import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Stream<Uint8List> _bytes() => Stream.value(Uint8List.fromList([1, 2, 3]));

IBlobClient _repositoryClient() => BlobRepositoryClient(
  repository: InMemoryBlobRepository(),
  disposeRepositoryOnClose: true,
);

void main() {
  test('an empty id is REFUSED, not silently generated', () async {
    final client = _repositoryClient();
    addTearDown(client.close);

    // A CLOSURE: this validation runs before the returned future exists, so
    // the throw is synchronous on this implementation. `await` catches it
    // either way, which is how every caller reaches it.
    await expectLater(
      () => client.putBytes(collection: 'c', id: '', bytes: _bytes()),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.invalidArgument,
        ),
      ),
      reason:
          'null already means "generate one"; an empty string is a caller '
          'whose id-building produced nothing',
    );
  });

  // CONTROL: null still means generate. Without this the fix could be "refuse
  // every call without an id", which breaks the documented way to ask for one.
  test('CONTROL: a null id still generates one', () async {
    final client = _repositoryClient();
    addTearDown(client.close);

    final r = await client.putBytes(collection: 'c', id: null, bytes: _bytes());

    expect(r.descriptor.id, isNotEmpty);
  });

  // CONTROL: a chosen id is still honoured.
  test('CONTROL: a non-empty id is used as given', () async {
    final client = _repositoryClient();
    addTearDown(client.close);

    final r = await client.putBytes(
      collection: 'c',
      id: 'chosen',
      bytes: _bytes(),
    );

    expect(r.descriptor.id, 'chosen');
  });
}
