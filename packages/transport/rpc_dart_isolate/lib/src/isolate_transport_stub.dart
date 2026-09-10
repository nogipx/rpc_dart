// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);

/// Fallback for a platform with NEITHER `dart:isolate` NOR `dart:js_interop`.
///
/// Not the web: `rpc_dart_isolate.dart` resolves web to
/// `isolate_transport_web.dart`, which is a real Worker-backed implementation.
/// Reaching this stub means no isolate mechanism exists at all, so [spawn]
/// throws [UnsupportedError].
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Uri? workerUri,
    Duration startupTimeout = const Duration(seconds: 30),
  }) {
    throw UnsupportedError(
      'RpcIsolateTransport is not available on this platform. '
      'Use a different transport when targeting the web.',
    );
  }
}

void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) {}
