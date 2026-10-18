// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The transport-authoring API: channels and frames, the message parser and
/// router, transport capabilities, and the helpers a server needs to drain.
///
/// Re-exports `package:rpc_dart/rpc_dart.dart`, so a transport imports this
/// library alone.
library;

export 'rpc_dart.dart';
export 'src/_index.dart'
    show
        // Channels and frames
        IRpcChannel,
        IRpcChannelOversizeClose,
        IRpcChannelProtocolClose,
        IRpcAdvisoryChannelError,
        IRpcMultiplexedChannel,
        RpcChannelFrame,
        RpcDecodedFrame,
        RpcFrameException,
        RpcMetadataViolation,
        RpcFrameMultiplexedChannel,
        RpcDirectMultiplexedChannel,
        // Messages and streams
        BufferedBroadcastController,
        RpcMessage,
        RpcMessageFrame,
        RpcMessageHeader,
        RpcMessageParser,
        RpcTransportMessage,
        RpcStreamIdManager,
        RpcStreamRouter,
        RpcConstants,
        // Transport capabilities
        IRpcConnectionBufferTotal,
        IRpcConnectionLossReporting,
        IRpcFlowControlled,
        IRpcNoMessageCredit,
        IRpcSecurityPolicyAware,
        IRpcStreamIdSequence,
        IRpcStreamReset,
        IRpcTransportReadiness,
        // Errors on the wire
        RpcNoConnectionException,
        grpcStatusFromHttpStatus,
        wireStatusFor,
        kInternalErrorWireMessage,
        // Ping, for a transport that probes a half-open path itself
        RpcEndpointPingExchange,
        RpcEndpointPingProtocol,
        // Server drain
        drainUntilIdle,
        inFlightResponderCalls,
        notifyWithoutDying;
