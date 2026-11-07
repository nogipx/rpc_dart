// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';

import 'stdio_channel.dart';

/// Serves one rpc_dart connection over stdin/stdout or injected byte streams.
///
/// Stdio is a single connection, so this server can be started once. A child
/// process creates a new server for each launch. Register a [RpcPeerMode] to
/// allow the server to initiate calls back to its caller.
final class RpcStdioServer extends IRpcServer {
  RpcStdioServer({
    required RpcServerMode mode,
    Stream<List<int>>? input,
    IOSink? output,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? prefaceTimeout = const Duration(seconds: 10),
    LogScope? logger,
    LogController? logController,
    bool compressionEnabled = false,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
  }) : _input = input,
       _output = output,
       _policy = policy,
       _prefaceTimeout = prefaceTimeout,
       _log = logger?.child('StdioServer') ?? LogScope.noop,
       _host = RpcConnectionHost(
         mode: mode,
         logger: logger?.child('StdioServer'),
         logController: logController,
         compressionEnabled: compressionEnabled,
       ),
       _onConnectionError = onConnectionError;

  /// Creates a responder server with the same contracts on its one endpoint.
  factory RpcStdioServer.createWithContracts({
    required List<RpcResponderContract> contracts,
    Stream<List<int>>? input,
    IOSink? output,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? prefaceTimeout = const Duration(seconds: 10),
    LogScope? logger,
    LogController? logController,
    bool compressionEnabled = false,
  }) => RpcStdioServer(
    mode: RpcResponderMode.contracts(contracts),
    input: input,
    output: output,
    policy: policy,
    prefaceTimeout: prefaceTimeout,
    logger: logger,
    logController: logController,
    compressionEnabled: compressionEnabled,
  );

  final Stream<List<int>>? _input;
  final IOSink? _output;
  final RpcSecurityPolicy _policy;
  final Duration? _prefaceTimeout;
  final LogScope _log;
  final RpcConnectionHost _host;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;

  RpcStdioChannel? _channel;
  RpcChannelTransport? _transport;
  Future<void>? _stopping;
  bool _started = false;
  bool _isRunning = false;

  @override
  bool get isRunning => _isRunning;

  @override
  List<RpcResponderEndpoint> get endpoints => _host.endpoints;

  @override
  Future<void> start() async {
    final stopping = _stopping;
    if (stopping != null) await stopping;
    if (_isRunning) return;
    if (_started) {
      throw StateError('RpcStdioServer cannot restart a consumed stdio stream');
    }
    _started = true;
    final channel = RpcStdioChannel(input: _input, output: _output);
    final transport = RpcChannelTransport.fromChannel(
      channel: channel,
      isClient: false,
      policy: _policy,
      prefaceTimeout: _prefaceTimeout,
      logger: _log,
    );
    _channel = channel;
    _transport = transport;
    _isRunning = true;

    unawaited(
      transport.ready.then(
        (_) {
          if (!_isRunning) return;
          try {
            _host.serve(
              transport,
              done: channel.done,
              debugLabel: 'StdioEndpoint',
            );
          } catch (error, stackTrace) {
            _report(error, stackTrace);
            unawaited(stop());
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_isRunning) return;
          _report(error, stackTrace);
          unawaited(stop());
        },
      ),
    );
    unawaited(
      channel.done.then((_) {
        if (_isRunning) unawaited(stop());
      }),
    );
  }

  @override
  Future<void> stop({Duration? drainTimeout}) {
    if (!_isRunning) return _stopping ?? Future<void>.value();
    _isRunning = false;
    return _stopping ??= _stopOnce(drainTimeout).whenComplete(() {
      _stopping = null;
    });
  }

  Future<void> _stopOnce(Duration? drainTimeout) async {
    await _host.stop(drainTimeout: drainTimeout);
    await _transport?.close();
    await _channel?.close();
  }

  void _report(Object error, StackTrace stackTrace) {
    _log.error('Stdio connection failed', error: error, stackTrace: stackTrace);
    if (_onConnectionError != null) {
      notifyWithoutDying(
        'onConnectionError',
        () => _onConnectionError(error, stackTrace),
        logger: _log,
      );
    }
  }
}
