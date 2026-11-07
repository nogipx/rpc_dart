// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';

/// A raw [IRpcChannel] over a process's standard input and output.
///
/// [input] and [output] are byte streams carrying rpc_dart frames, not
/// JSON-RPC lines. Use the same channel with [RpcChannelTransport.fromChannel]
/// on each side, choosing opposite `isClient` roles. The caller owns the
/// process and the output sink; closing this channel does not close stdout.
final class RpcStdioChannel extends IRpcChannel {
  RpcStdioChannel({
    Stream<List<int>>? input,
    IOSink? output,
    this.closeOutput = false,
  }) : _output = output ?? stdout {
    _subscription = (input ?? stdin).listen(
      (chunk) => _incoming.add(Uint8List.fromList(chunk)),
      onError: (Object error, StackTrace stackTrace) {
        if (!_incoming.isClosed) _incoming.addError(error, stackTrace);
        unawaited(close());
      },
      onDone: () => unawaited(close()),
    );
    _incoming
      ..onPause = _subscription.pause
      ..onResume = _subscription.resume;
  }

  /// Whether [close] closes [output]. Use true for a child process's stdin.
  final bool closeOutput;

  final IOSink _output;
  final Completer<void> _done = Completer<void>();

  /// Completes when the input ends or this channel closes.
  Future<void> get done => _done.future;
  final _incoming = StreamController<Uint8List>();
  late final StreamSubscription<List<int>> _subscription;
  bool _closed = false;
  Future<void>? _closing;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('RPC stdio channel is closed');
    _output.add(data);
    await _output.flush();
  }

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    await _subscription.cancel();
    if (closeOutput) await _output.close();
    if (!_incoming.isClosed) await _incoming.close();
  }
}
