// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// connect(cancellationToken:) abandons the open when the token is cancelled:
// a peer that accepted TCP and never answers the upgrade sees its socket
// closed at once, and the connect fails CANCELLED. Without the token nothing
// ends that wait but connectTimeout -- and with connectTimeout null, nothing.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// A listener that accepts and never writes, and reports each socket's end.
Future<(ServerSocket, Future<void> accepted, Future<void> ended)>
_silentPeer() async {
  final ss = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = Completer<void>();
  final ended = Completer<void>();
  ss.listen((s) {
    if (!accepted.isCompleted) accepted.complete();
    void end() {
      if (!ended.isCompleted) ended.complete();
    }

    s.listen((_) {}, onDone: end, onError: (_) => end());
  });
  addTearDown(ss.close);
  return (ss, accepted.future, ended.future);
}

Future<bool> _within(Future<void> f, Duration within) => Future.any([
  f.then((_) => true),
  Future<bool>.delayed(within, () => false),
]);

void main() {
  test('a cancelled connect closes its socket and fails CANCELLED', () async {
    final (ss, accepted, ended) = await _silentPeer();
    final token = RpcCancellationToken();
    final opening = RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${ss.port}/'),
      connectTimeout: null,
      cancellationToken: token,
    );
    await accepted;

    token.cancel('test');
    final outcome = await Future.any<Object?>([
      opening.then<Object?>((_) => 'opened', onError: (Object e) => e),
      Future<Object?>.delayed(const Duration(seconds: 1), () => 'pending'),
    ]);
    expect(
      outcome,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.cancelled,
      ),
    );
    expect(
      await _within(ended, const Duration(seconds: 1)),
      isTrue,
      reason: 'the peer still holds an open socket after the cancel',
    );
  });

  test('a token cancelled before the call opens nothing', () async {
    final (ss, accepted, _) = await _silentPeer();
    await expectLater(
      RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${ss.port}/'),
        cancellationToken: RpcCancellationToken.cancelled(),
      ),
      throwsA(isA<RpcCancelledException>()),
    );
    expect(await _within(accepted, const Duration(milliseconds: 200)), isFalse);
  });
}
