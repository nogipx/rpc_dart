// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The transport-authoring API: channels and frames, the message parser and
/// router, the flow-control interfaces, and the helpers a server needs to
/// drain.
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
        RpcRecentIds,
        RpcStreamRouter,
        RpcConstants,
        // Protobuf wire format
        RpcProtoReader,
        RpcProtoWireType,
        RpcProtoWriter,
        // What IRpcTransport's optional members return
        IRpcFlowCredit,
        IRpcConnectionBuffer,
        // Errors on the wire
        RpcTrailers,
        requestEndedMidMessage,
        responseEndedMidMessage,
        RpcNoConnectionException,
        grpcStatusFromHttpStatus,
        wireStatusFor,
        kInternalErrorWireMessage,
        rpcIsUnsafeCodePoint,
        rpcPeerText,
        // Ping, for a transport that probes a half-open path itself
        RpcEndpointPingExchange,
        RpcEndpointPingProtocol,
        // Server connections, writes and drain
        RpcConnectionHost,
        RpcWriteBacklog,
        RpcWriteCoalescer,
        drainUntilIdle,
        inFlightResponderCalls,
        notifyWithoutDying;
