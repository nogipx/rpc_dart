// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
@TestOn('vm || node')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

void main() {
  test('RPC put/get/list round-trip (web)', () async {
    final env = await BlobServiceFactory.inMemory(
      storage: InMemoryBlobRepository(),
    );

    final data = Uint8List.fromList(List<int>.generate(4096, (i) => i % 256));
    await env.client.putBytes(
      collection: 'c',
      id: 'b1',
      bytes: Stream.value(data),
    );

    // Full download, reassembled from frames.
    final builder = BytesBuilder(copy: false);
    await for (final frame in env.client.get('c', 'b1')) {
      builder.add(frame.bytes);
    }
    expect(builder.toBytes(), equals(data));

    final listed = await env.client.list('c');
    expect(listed.items.map((d) => d.id), contains('b1'));

    await env.dispose();
  });

  test('RPC get-stream cancel mid-download does not deadlock (web)', () async {
    // Small upload chunks so the stored blob spans many download frames and
    // the cancel below lands while the server stream is still active -- the
    // dart2js cancel-deadlock pattern.
    final env = await BlobServiceFactory.inMemory(
      storage: InMemoryBlobRepository(),
      uploadChunkBytes: 4096,
    );

    final data = Uint8List.fromList(
      List<int>.generate(512 * 1024, (i) => i % 256),
    );
    await env.client.putBytes(
      collection: 'c',
      id: 'big',
      bytes: Stream.value(data),
    );

    var received = 0;
    final sub = env.client.get('c', 'big').listen((_) => received++);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(received, greaterThan(0));
    expect(received, lessThan(data.length ~/ 4096));

    await sub.cancel().timeout(const Duration(seconds: 3));
    await env.dispose();
  });
}
