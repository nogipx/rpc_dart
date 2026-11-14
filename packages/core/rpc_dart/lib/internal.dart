// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Infrastructure primitives for integrations that own stream lifetimes.
///
/// This is an explicit integration surface, not a re-export of package internals.
/// Stream helpers do not serialize data or manage transport flow-control credit.
library;

export 'src/core/bounded_stream_bridge.dart'
    show BoundedStreamBridge, StreamBufferLimits, StreamBridgeStats;
export 'src/core/buffer_budget.dart' show RpcBufferBudget;
export 'src/core/errors.dart' show RpcPeerFaultException;
export 'src/core/stream_bridge.dart' show StreamBridge;
export 'src/core/stream_source.dart' show StreamSource;
export 'src/rpc/transports/stream_buffer_ledger.dart'
    show RpcStreamBufferLedger, RpcBufferAdmission;
