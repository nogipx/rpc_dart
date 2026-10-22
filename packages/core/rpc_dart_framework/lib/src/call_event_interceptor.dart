// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_app_config.dart';

/// An observer that hands every finished call to [onEvent] as an
/// [RpcCallEvent].
abstract class CallEventInterceptor
    extends RpcCallObserverInterceptor<(RpcCallInfo, RpcMethodType)> {
  const CallEventInterceptor();

  /// A call ended.
  void onEvent(RpcCallEvent event);

  @override
  (RpcCallInfo, RpcMethodType) onCallStart(
    RpcCallInfo call,
    RpcMethodType type,
  ) => (call, type);

  @override
  void onCallEnd(
    (RpcCallInfo, RpcMethodType) state,
    RpcCallOutcome outcome,
    Duration duration,
  ) {
    final (call, type) = state;
    onEvent(
      RpcCallEvent(
        serviceName: call.serviceName,
        methodName: call.methodName,
        callType: type,
        duration: duration,
        outcome: outcome,
        context: call.context,
      ),
    );
  }
}
