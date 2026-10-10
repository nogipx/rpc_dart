// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _ResponderPipelineContext on RpcResponderPipelineMixin {
  // ---------------------------------------------------------------------------
  // Context helpers
  // ---------------------------------------------------------------------------

  RpcContext _cacheContext(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    var context = _createContextFromMessage(message);
    // Attach logger with traceId/requestId and service/method name
    final methodKey = state.methodKey; // e.g. 'Calculator.calculate'
    final scopeName = methodKey ?? 'unknown';
    final logScope = _log
        .child(scopeName)
        .withContext(requestId: context.requestId, traceId: context.traceId);
    context = context.withLog(logScope);

    // Provide a per-call RpcCallScope so handlers can register cleanup that
    // auto-disposes when the call ends (success, error, cancellation, deadline).
    // Keyed by the RpcCallScope type to match the documented access pattern
    // `context.getValue<RpcCallScope>(RpcCallScope)`. Closed in _cleanupStream;
    // it also self-closes on the context's cancellation token / deadline.
    final callScope = RpcCallScope(context: context);
    context = context.withValue(RpcCallScope, callScope);
    state.cacheContext(context);

    // Enforce the client deadline (grpc-timeout) on the server: arm a timer
    // that cancels the handler's cancellation token when the deadline passes.
    // Dart cannot preempt a bare `await`, but cooperative handlers (checking
    // the token / `isExpired`, or reading the request stream) unwind, and the
    // response path is torn down so a late result is discarded.
    final deadline = context.deadline;
    if (deadline != null) {
      state.deadlineAt = deadline;
      state.armDeadline(
        deadline.difference(context.clock()),
        () => _onDeadlineExceeded(state),
      );
    }
    final token = context.cancellationToken;
    if (token != null) _streamByToken[token] = state;
    return context;
  }

  RpcContext _ensureResponderContext(RpcResponderStreamState state) {
    final cached = state.cachedContext;
    if (cached != null) return cached;

    final source =
        state.metadataMessage ??
        state.lastPayloadMessage ??
        RpcTransportMessage(
          streamId: state.id,
          methodPath: state.methodKey != null
              ? _methodPathFromKey(state.methodKey!)
              : '/UnknownService/UnknownMethod',
        );

    return _cacheContext(state, source);
  }

  RpcContext _createContextFromMessage(RpcTransportMessage message) {
    // Repeated keys are JOINED with a comma, not overwritten. gRPC allows
    // Custom-Metadata keys to repeat and RFC 9110 s5.3 makes repeated field
    // lines equivalent to one comma-separated line, so overwriting silently
    // drops values -- and disagrees with RpcMetadata, which keeps both and
    // whose getHeaderValue returns the FIRST.
    //
    // For a header rpc_dart parses as a single value (grpc-timeout,
    // grpc-encoding) a duplicate then yields something that fails to parse
    // rather than one arbitrarily chosen value, which is the safer reading:
    // it is not for us to pick which deadline the peer meant.
    final headers = <String, String>{};
    if (message.metadata != null) {
      for (final header in message.metadata!.headers) {
        if (!header.name.startsWith(':') &&
            header.name != 'content-type' &&
            header.name != 'te' &&
            !RpcHeaders.isHiddenFromHandler(header.name)) {
          final existing = headers[header.name];
          headers[header.name] = existing == null
              ? header.value
              : '$existing,${header.value}';
        }
      }
    }

    // Adopt the caller's request id as the trace id below is adopted, and AT
    // CONSTRUCTION so no id is minted just to be replaced. Ignore it and the
    // two sides log different ids for one call, which cannot then be joined.
    //
    // Both headers are protocol-reserved, so an application cannot forge them
    // through ordinary metadata, and both arrive length- and charset-checked by
    // validateMetadata. Correlation only: nothing keys state off this, so a
    // peer repeating an id costs it nothing but its own confusing logs.
    final clientRequestId = headers[RpcHeaders.xRequestId];
    var context = RpcContext.withHeaders(
      headers,
      requestId: (clientRequestId != null && clientRequestId.isNotEmpty)
          ? clientRequestId
          : null,
    );

    final timeoutHeader = context.getHeader(RpcHeaders.grpcTimeout);
    if (timeoutHeader != null) {
      final timeout = RpcMetadata.parseGrpcTimeout(timeoutHeader);
      if (timeout != null) {
        context = context.withDeadline(context.clock().add(timeout));
      }
    }

    final clientTraceId = context.getHeader(RpcHeaders.xTraceId);
    if (clientTraceId != null) {
      context = context.withTraceId(clientTraceId);
    } else {
      // DERIVE, as the caller side does. A peer that sends no `x-trace-id` sends
      // no `x-request-id` either -- both are ours, not gRPC's -- so minting here
      // drew a second token for an id the request id above already names.
      // `traceIdFor` falls back to a fresh token when that id is not one of ours.
      context = context.withTraceId(
        RpcContextUtils.traceIdFor(context.requestId),
      );
    }

    // Attach a cancellation token so drain() can signal active handlers.
    if (context.cancellationToken == null) {
      context = context.withCancellation(RpcCancellationToken());
    }

    return context;
  }

  // ---------------------------------------------------------------------------
  // Utility
  // ---------------------------------------------------------------------------

  /// The transport's policy owns the grammar; this only asks it.
  ///
  /// It used to hold a fourth copy with a HARDCODED 512, which is what made
  /// `maxMethodPathLength` monotone downward only: raise it past 512 and this
  /// refused the path afterwards.
  (String, String)? _parseMethodPath(String methodPath) =>
      _policyOfTransport(transport).parseMethodPath(methodPath);

  /// The inverse of [_parseMethodPath]; both rules live in `metadata.dart`.
  String _methodPathFromKey(String methodKey) =>
      rpcMethodPathFromKey(methodKey);

  bool _isPingMethodKey(String methodKey) =>
      methodKey == RpcEndpointPingProtocol.methodKey;
}
