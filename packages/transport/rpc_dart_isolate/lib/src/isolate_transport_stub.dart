// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'port_channel.dart';

export 'port_channel.dart' show RpcIsolateEntrypoint;

/// Fallback for a platform with NEITHER `dart:isolate` NOR `dart:js_interop`.
///
/// Not the web: `rpc_dart_isolate.dart` resolves web to
/// `isolate_transport_web.dart`, which is a real Worker-backed implementation.
/// Reaching this stub means no isolate mechanism exists at all, so [spawn]
/// fails with [UnsupportedError] -- through its future, as the real
/// implementations fail, so a `.catchError` sees it.
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Uri? workerUri,
    Duration startupTimeout = const Duration(seconds: 30),
    LogScope? logger,
  }) async {
    throw UnsupportedError(
      'RpcIsolateTransport is not available on this platform: it has neither '
      'dart:isolate nor dart:js_interop.',
    );
  }
}

void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy? policy,
}) {}
