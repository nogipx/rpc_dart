// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The application API: contracts, endpoints, context, errors, codecs,
/// resilience, logging and the channel transport with its in-memory pairs.
///
/// A transport author also imports `package:rpc_dart/transport.dart`, which
/// re-exports this library.
///
/// Every name is listed on purpose. The integration-only primitives have their own explicit list in
/// `internal.dart`. Other names are internal to the package, whatever their spelling.
///
/// `dart:typed_data` is re-exported whole: payloads are `Uint8List`, and the
/// generator emits `part` files, which cannot import it themselves.
library;

export 'dart:typed_data';

export 'logger.dart';
export 'src/_index.dart'
    show
        // Contracts and annotations
        IRpcContract,
        RpcCallerContract,
        RpcResponderContract,
        RpcPeerContract,
        RpcMethod,
        RpcMethodType,
        RpcService,
        RpcServiceKind,
        RpcRemoved,
        RpcDataTransferMode,
        // Context and cancellation
        RpcContext,
        RpcContextKey,
        RpcCallScope,
        RpcCancellationToken,
        RpcCancelledException,
        RpcDeadlineExceededException,
        // Codecs
        IRpcSerializable,
        IRpcCodec,
        RpcCodec,
        RpcBinaryCodec,
        RpcCborCodec,
        approxJsonBytes,
        // Primitive messages
        RpcPrimitiveMessage,
        RpcString,
        RpcStringX,
        RpcInt,
        RpcIntX,
        RpcDouble,
        RpcDoubleX,
        RpcNum,
        RpcNumX,
        RpcBool,
        RpcBoolX,
        RpcNull,
        RpcNullX,
        RpcList,
        // Endpoints and interceptors
        RpcEndpointBase,
        RpcCallerEndpoint,
        RpcResponderEndpoint,
        RpcPeerEndpoint,
        RpcEndpointHealth,
        RpcEndpointMetrics,
        RpcCallerEndpointMetrics,
        RpcResponderEndpointMetrics,
        RpcPeerEndpointMetrics,
        RpcEndpointPingResult,
        IRpcInterceptor,
        RpcCallObserverInterceptor,
        RpcCallOutcome,
        RpcCallSucceeded,
        RpcCallFailed,
        RpcCallCancelled,
        RpcCallInfo,
        RpcCallDirection,
        RpcUnaryNext,
        RpcServerStreamNext,
        RpcClientStreamNext,
        RpcBidirectionalStreamNext,
        // Errors and status
        RpcException,
        RpcStatusException,
        RpcClosedException,
        RpcNoConnectionException,
        RpcMetadataViolationException,
        RpcStatus,
        RpcErrorDetail,
        RpcErrorInfo,
        RpcBadRequest,
        RpcFieldViolation,
        RpcDebugInfo,
        RpcRetryInfo,
        RpcRawErrorDetail,
        // Metadata
        RpcMetadata,
        RpcHeader,
        RpcHeaders,
        // Limits
        RpcSecurityPolicy,
        RpcContentTypeValidation,
        // Health
        RpcHealthStatus,
        RpcHealthLevel,
        RpcHealthLevelSeverity,
        GrpcHealthCheckContract,
        GrpcHealthCheckRequest,
        GrpcHealthCheckResponse,
        GrpcHealthServiceStatus,
        GrpcServingStatus,
        // Compression
        RpcCompressionCodec,
        RpcGrpcCompression,
        // Resilience
        RpcBackoffPolicy,
        RpcExponentialBackoff,
        RpcFixedBackoff,
        RpcCircuitBreakerInterceptor,
        RpcCircuitBreakerOpenException,
        RpcCircuitBreakerState,
        RpcClientConnection,
        RpcClientConnectionMetrics,
        RpcClientConnectionState,
        RpcClientConnecting,
        RpcClientDisconnected,
        RpcClientIdle,
        RpcClientOffline,
        RpcClientOnline,
        RpcClientSuspended,
        RpcReconnectPolicy,
        RpcRateLimitInterceptor,
        RpcRateLimit,
        RpcRateLimitException,
        RpcRetryInterceptor,
        RpcRetryPredicate,
        // Transports and servers
        IRpcTransport,
        IRpcServer,
        RpcServerMode,
        RpcResponderMode,
        RpcPeerMode,
        RpcChannelTransport;
