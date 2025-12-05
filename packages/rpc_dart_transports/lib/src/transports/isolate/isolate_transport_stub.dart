// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

typedef RpcIsolateEntrypoint = void Function(
    IRpcTransport transport, Map<String, dynamic> customParams);

/// Fallback stub for platforms without `dart:isolate` (e.g., web).
/// Always throws [UnsupportedError] when used.
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
  }) {
    throw UnsupportedError(
      'RpcIsolateTransport is not available on this platform. '
      'Use a different transport when targeting the web.',
    );
  }
}
