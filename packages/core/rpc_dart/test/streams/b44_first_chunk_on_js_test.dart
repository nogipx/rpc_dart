// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-44 on the runtime it is actually reported on.
//
// The consumer sees the first chunk of a client-stream arrive with its identity
// fields null — 86 times in 3.6 days — on dart2js through a browser WebSocket,
// and *on the VM never*. Every bench so far, including round 383's first two
// passes and the run against the consumer's own 55159adf, has been on the VM.
// That is the one axis never varied.
//
// This file is deliberately transport-free: it runs the core pipeline over
// RpcChannelTransport.pair() under dart2js, so a difference here is the
// COMPILER's, not the socket's.

@TestOn('js')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class Chunk implements IRpcSerializable {
  const Chunk({required this.index, this.blobId, this.vaultId, this.total});

  final int index;
  final String? blobId;
  final String? vaultId;
  final int? total;

  factory Chunk.fromJson(Map<String, dynamic> json) => Chunk(
    index: json['i'] as int,
    blobId: json['b'] as String?,
    vaultId: json['v'] as String?,
    total: json['t'] as int?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'i': index,
    if (blobId != null) 'b': blobId,
    if (vaultId != null) 'v': vaultId,
    if (total != null) 't': total,
  };
}

final _codec = RpcCodec<Chunk>(Chunk.fromJson);
final _reply = RpcCodec<RpcString>(RpcString.fromJson);

int badFirst = 0;
int short = 0;
int calls = 0;

final class _Upload extends RpcResponderContract {
  _Upload() : super('Blob');

  @override
  void setup() {
    addClientStreamMethod<Chunk, RpcString>(
      methodName: 'put',
      handler: (chunks, {RpcContext? context}) async {
        var n = 0;
        var firstBad = false;
        await for (final c in chunks) {
          n++;
          // The consumer's own check, on the message the handler sees FIRST.
          if (n == 1 && (c.blobId == null || c.vaultId == null)) {
            firstBad = true;
          }
        }
        calls++;
        if (firstBad) badFirst++;
        if (n != 17) short++;
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _reply,
    );
  }
}

/// 17 chunks: the identity rides on the first only.
Stream<Chunk> _blob(int bytes) async* {
  final pad = 'x' * bytes;
  yield Chunk(index: 0, blobId: 'blob-$pad', vaultId: 'vault-1', total: 17);
  for (var i = 1; i < 17; i++) {
    yield Chunk(index: i);
  }
}

void main() {
  setUp(() => calls = badFirst = short = 0);

  Future<void> upload(RpcCallerEndpoint caller, int bytes) async {
    try {
      await caller
          .clientStream<Chunk, RpcString>(
            serviceName: 'Blob',
            methodName: 'put',
            requestCodec: _codec,
            responseCodec: _reply,
          )(_blob(bytes))
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  test('WITNESS: the first chunk keeps its ids on dart2js', () async {
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Upload());
    responder.start();

    // Many uploads on ONE connection, which is the consumer's shape: a
    // long-lived server, streams opened and torn down as it goes.
    for (var i = 0; i < 25; i++) {
      await upload(caller, 1024);
    }

    expect(
      badFirst,
      0,
      reason:
          '$badFirst of $calls uploads gave the handler a first chunk with null '
          'ids — B-44 reproduced on dart2js',
    );
    expect(
      short,
      0,
      reason: '$short of $calls uploads were short of 17 chunks',
    );

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('WITNESS: concurrent uploads keep their ids on dart2js', () async {
    // Concurrency is where a shared id space and a shared pipeline meet, and
    // the consumer uploads several blobs at once.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Upload());
    responder.start();

    await Future.wait([for (var i = 0; i < 12; i++) upload(caller, 16 * 1024)]);

    expect(
      badFirst,
      0,
      reason: '$badFirst of $calls concurrent uploads lost the first chunk ids',
    );
    expect(short, 0, reason: '$short of $calls were short of 17 chunks');

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
