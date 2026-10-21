// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Canonical gRPC status code names (uppercase) used as the value of the
/// `rpc.grpc.status` attribute.
///
/// Returns `UNKNOWN` for codes outside the 0..16 range so the attribute is
/// always bounded to a known small set.
String rpcGrpcStatusName(int code) => RpcStatus.fromCode(code).grpcName;

/// Extracts the gRPC status from a thrown error.
///
/// - [RpcStatusException] → its [RpcStatusException.statusCode]
/// - any other throwable → [RpcStatus.unknown]
RpcStatus rpcStatusCodeFromError(Object error) {
  if (error is RpcStatusException) return error.statusCode;
  return RpcStatus.unknown;
}
