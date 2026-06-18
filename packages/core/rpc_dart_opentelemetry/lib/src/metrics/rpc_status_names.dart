// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Canonical gRPC status code names (uppercase) used as the value of the
/// `rpc.grpc.status_code` attribute per OpenTelemetry semantic conventions.
///
/// Returns `UNKNOWN` for codes outside the 0..16 range so the attribute is
/// always bounded to a known small set.
String rpcGrpcStatusName(int code) {
  switch (code) {
    case RpcStatus.ok:
      return 'OK';
    case RpcStatus.cancelled:
      return 'CANCELLED';
    case RpcStatus.unknown:
      return 'UNKNOWN';
    case RpcStatus.invalidArgument:
      return 'INVALID_ARGUMENT';
    case RpcStatus.deadlineExceeded:
      return 'DEADLINE_EXCEEDED';
    case RpcStatus.notFound:
      return 'NOT_FOUND';
    case RpcStatus.alreadyExists:
      return 'ALREADY_EXISTS';
    case RpcStatus.permissionDenied:
      return 'PERMISSION_DENIED';
    case RpcStatus.resourceExhausted:
      return 'RESOURCE_EXHAUSTED';
    case RpcStatus.failedPrecondition:
      return 'FAILED_PRECONDITION';
    case RpcStatus.aborted:
      return 'ABORTED';
    case RpcStatus.outOfRange:
      return 'OUT_OF_RANGE';
    case RpcStatus.unimplemented:
      return 'UNIMPLEMENTED';
    case RpcStatus.internal:
      return 'INTERNAL';
    case RpcStatus.unavailable:
      return 'UNAVAILABLE';
    case RpcStatus.dataLoss:
      return 'DATA_LOSS';
    case RpcStatus.unauthenticated:
      return 'UNAUTHENTICATED';
    default:
      return 'UNKNOWN';
  }
}

/// Extracts the gRPC status code from a thrown error.
///
/// - [RpcStatusException] → its [RpcStatusException.statusCode]
/// - any other throwable → [RpcStatus.unknown]
int rpcStatusCodeFromError(Object error) {
  if (error is RpcStatusException) return error.statusCode;
  return RpcStatus.unknown;
}
