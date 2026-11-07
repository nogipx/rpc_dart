// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:rpc_dart/transport.dart';

import 'stdio_channel.dart';

/// Client-side rpc_dart transport over a byte-stream stdio channel.
class RpcStdioCallerTransport extends RpcChannelTransport {
  /// Takes ownership of [channel]. Its output sink is closed only when the
  /// channel was constructed with `closeOutput: true`.
  RpcStdioCallerTransport(
    RpcStdioChannel channel, {
    super.policy,
    super.prefaceTimeout,
    super.logger,
  }) : super.fromChannel(channel: channel, isClient: true);

  /// Connects to a child process whose stdin/stdout carry rpc_dart frames.
  ///
  /// Closing the transport closes the child's stdin, but does not kill or
  /// await the process. The caller owns [process] and its stderr stream.
  factory RpcStdioCallerTransport.fromProcess(
    Process process, {
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? prefaceTimeout = const Duration(seconds: 30),
    LogScope? logger,
  }) => RpcStdioCallerTransport(
    RpcStdioChannel(
      input: process.stdout,
      output: process.stdin,
      closeOutput: true,
    ),
    policy: policy,
    prefaceTimeout: prefaceTimeout,
    logger: logger,
  );
}
