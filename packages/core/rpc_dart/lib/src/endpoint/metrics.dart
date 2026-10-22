// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// A snapshot of an endpoint's counters, from
/// [RpcEndpointBase.collectEndpointMetrics].
///
/// The responder fields are null on an endpoint that serves no calls (a
/// caller), the caller fields on one that makes none (a responder); a peer
/// endpoint fills both. [toJson] is the same data as a map, which is what an
/// endpoint's [RpcHealthStatus.details] carries.
final class RpcEndpointMetrics {
  /// Creates a snapshot; the endpoints build these.
  const RpcEndpointMetrics({
    required this.isActive,
    required this.interceptorCount,
    required this.transportClosed,
    required this.transportType,
    this.debugLabel,
    this.registeredContracts,
    this.registeredMethods,
    this.isListening,
    this.isDraining,
    this.openStreams,
    this.preMethodBufferedBytes,
    this.metadataStreams,
    this.bufferedMessages,
    this.preBindBuffers,
    this.activeResponders,
    this.contractKeys,
    this.pendingRequests,
    this.trackedMethods,
    this.activeMethodKeys,
  });

  /// Whether the endpoint is open.
  final bool isActive;

  /// Interceptors added to the endpoint.
  final int interceptorCount;

  /// Whether the transport is closed.
  final bool transportClosed;

  /// The transport's runtime type, for diagnostics.
  final String transportType;

  /// The endpoint's debug label, if it has one.
  final String? debugLabel;

  /// Responder: contracts registered.
  final int? registeredContracts;

  /// Responder: methods registered across the contracts.
  final int? registeredMethods;

  /// Responder: whether it listens to the transport.
  final bool? isListening;

  /// Responder: whether it refuses new calls while finishing the open ones.
  final bool? isDraining;

  /// Responder: per-call stream states held, finished or not.
  final int? openStreams;

  /// Responder: payload bytes parked before a call's method is known. Sits
  /// at 0 between calls; a number that only climbs means the budget is not
  /// being released and calls will start being refused.
  final int? preMethodBufferedBytes;

  /// Responder: streams whose opening metadata has arrived.
  final int? metadataStreams;

  /// Responder: streams holding a request message for a handler.
  final int? bufferedMessages;

  /// Responder: streams buffering frames before a handler is bound.
  final int? preBindBuffers;

  /// Responder: handlers running, the number a drain waits on.
  final int? activeResponders;

  /// Responder: the registered services.
  final List<String>? contractKeys;

  /// Caller: calls in flight.
  final int? pendingRequests;

  /// Caller: methods with a call in flight.
  final int? trackedMethods;

  /// Caller: `service/method` of each method with a call in flight.
  final List<String>? activeMethodKeys;

  /// The fields that are set, under their own names; an empty list is left
  /// out.
  Map<String, Object?> toJson() => {
    'isActive': isActive,
    'interceptorCount': interceptorCount,
    'transportClosed': transportClosed,
    'transportType': transportType,
    'debugLabel': ?debugLabel,
    'registeredContracts': ?registeredContracts,
    'registeredMethods': ?registeredMethods,
    'isListening': ?isListening,
    'isDraining': ?isDraining,
    'openStreams': ?openStreams,
    'preMethodBufferedBytes': ?preMethodBufferedBytes,
    'metadataStreams': ?metadataStreams,
    'bufferedMessages': ?bufferedMessages,
    'preBindBuffers': ?preBindBuffers,
    'activeResponders': ?activeResponders,
    if (contractKeys?.isNotEmpty ?? false) 'contractKeys': contractKeys,
    'pendingRequests': ?pendingRequests,
    'trackedMethods': ?trackedMethods,
    if (activeMethodKeys?.isNotEmpty ?? false)
      'activeMethodKeys': activeMethodKeys,
  };

  @override
  String toString() => 'RpcEndpointMetrics(${toJson()})';
}

/// What the responder half adds to [RpcEndpointMetrics].
typedef _ResponderCounts = ({
  int registeredContracts,
  int registeredMethods,
  bool isListening,
  bool isDraining,
  int openStreams,
  int preMethodBufferedBytes,
  int metadataStreams,
  int bufferedMessages,
  int preBindBuffers,
  int activeResponders,
  List<String> contractKeys,
});

/// What the caller half adds to [RpcEndpointMetrics].
typedef _CallerCounts = ({
  int pendingRequests,
  int trackedMethods,
  List<String> activeMethodKeys,
});
