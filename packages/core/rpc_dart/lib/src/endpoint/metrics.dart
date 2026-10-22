// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// A snapshot of an endpoint's counters, from
/// [RpcEndpointBase.collectEndpointMetrics].
///
/// Each endpoint returns its own subtype: [RpcCallerEndpointMetrics],
/// [RpcResponderEndpointMetrics] or [RpcPeerEndpointMetrics]. This type holds
/// what every endpoint has. [toJson] is the same data as a map, which is what
/// an endpoint's [RpcHealthStatus.details] carries.
final class RpcEndpointMetrics {
  /// Creates a snapshot; the endpoints build these.
  const RpcEndpointMetrics({
    required this.isActive,
    required this.interceptorCount,
    required this.transportClosed,
    required this.transportType,
    this.debugLabel,
  });

  RpcEndpointMetrics._copy(RpcEndpointMetrics m)
    : isActive = m.isActive,
      interceptorCount = m.interceptorCount,
      transportClosed = m.transportClosed,
      transportType = m.transportType,
      debugLabel = m.debugLabel;

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

  /// The fields under their own names; an empty list is left out.
  Map<String, Object?> toJson() => {
    'isActive': isActive,
    'interceptorCount': interceptorCount,
    'transportClosed': transportClosed,
    'transportType': transportType,
    'debugLabel': ?debugLabel,
  };

  @override
  String toString() => '$runtimeType(${toJson()})';
}

/// What an [RpcCallerEndpoint] reports.
final class RpcCallerEndpointMetrics extends RpcEndpointMetrics {
  /// Creates a snapshot; the endpoints build these.
  const RpcCallerEndpointMetrics({
    required super.isActive,
    required super.interceptorCount,
    required super.transportClosed,
    required super.transportType,
    super.debugLabel,
    required this.pendingRequests,
    required this.trackedMethods,
    required this.activeMethodKeys,
  });

  RpcCallerEndpointMetrics._from(super.m, _CallerCounts c)
    : pendingRequests = c.pendingRequests,
      trackedMethods = c.trackedMethods,
      activeMethodKeys = c.activeMethodKeys,
      super._copy();

  /// Calls in flight.
  final int pendingRequests;

  /// Methods with a call in flight.
  final int trackedMethods;

  /// `service/method` of each method with a call in flight.
  final List<String> activeMethodKeys;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'pendingRequests': pendingRequests,
    'trackedMethods': trackedMethods,
    if (activeMethodKeys.isNotEmpty) 'activeMethodKeys': activeMethodKeys,
  };
}

/// What an [RpcResponderEndpoint] reports.
final class RpcResponderEndpointMetrics extends RpcEndpointMetrics {
  /// Creates a snapshot; the endpoints build these.
  const RpcResponderEndpointMetrics({
    required super.isActive,
    required super.interceptorCount,
    required super.transportClosed,
    required super.transportType,
    super.debugLabel,
    required this.registeredContracts,
    required this.registeredMethods,
    required this.isListening,
    required this.isDraining,
    required this.openStreams,
    required this.preMethodBufferedBytes,
    required this.metadataStreams,
    required this.bufferedMessages,
    required this.preBindBuffers,
    required this.activeResponders,
    required this.contractKeys,
  });

  RpcResponderEndpointMetrics._from(super.m, _ResponderCounts r)
    : registeredContracts = r.registeredContracts,
      registeredMethods = r.registeredMethods,
      isListening = r.isListening,
      isDraining = r.isDraining,
      openStreams = r.openStreams,
      preMethodBufferedBytes = r.preMethodBufferedBytes,
      metadataStreams = r.metadataStreams,
      bufferedMessages = r.bufferedMessages,
      preBindBuffers = r.preBindBuffers,
      activeResponders = r.activeResponders,
      contractKeys = r.contractKeys,
      super._copy();

  /// Contracts registered.
  final int registeredContracts;

  /// Methods registered across the contracts.
  final int registeredMethods;

  /// Whether it listens to the transport.
  final bool isListening;

  /// Whether it refuses new calls while finishing the open ones.
  final bool isDraining;

  /// Per-call stream states held, finished or not.
  final int openStreams;

  /// Payload bytes parked before a call's method is known. Sits at 0 between
  /// calls; a number that only climbs means the budget is not being released
  /// and calls will start being refused.
  final int preMethodBufferedBytes;

  /// Streams whose opening metadata has arrived.
  final int metadataStreams;

  /// Streams holding a request message for a handler.
  final int bufferedMessages;

  /// Streams buffering frames before a handler is bound.
  final int preBindBuffers;

  /// Handlers running, the number a drain waits on.
  final int activeResponders;

  /// The registered services.
  final List<String> contractKeys;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'registeredContracts': registeredContracts,
    'registeredMethods': registeredMethods,
    'isListening': isListening,
    'isDraining': isDraining,
    'openStreams': openStreams,
    'preMethodBufferedBytes': preMethodBufferedBytes,
    'metadataStreams': metadataStreams,
    'bufferedMessages': bufferedMessages,
    'preBindBuffers': preBindBuffers,
    'activeResponders': activeResponders,
    if (contractKeys.isNotEmpty) 'contractKeys': contractKeys,
  };
}

/// What an [RpcPeerEndpoint] reports: the responder counters and the caller
/// ones.
final class RpcPeerEndpointMetrics extends RpcResponderEndpointMetrics {
  /// Creates a snapshot; the endpoints build these.
  const RpcPeerEndpointMetrics({
    required super.isActive,
    required super.interceptorCount,
    required super.transportClosed,
    required super.transportType,
    super.debugLabel,
    required super.registeredContracts,
    required super.registeredMethods,
    required super.isListening,
    required super.isDraining,
    required super.openStreams,
    required super.preMethodBufferedBytes,
    required super.metadataStreams,
    required super.bufferedMessages,
    required super.preBindBuffers,
    required super.activeResponders,
    required super.contractKeys,
    required this.pendingRequests,
    required this.trackedMethods,
    required this.activeMethodKeys,
  });

  RpcPeerEndpointMetrics._from(super.m, super.r, _CallerCounts c)
    : pendingRequests = c.pendingRequests,
      trackedMethods = c.trackedMethods,
      activeMethodKeys = c.activeMethodKeys,
      super._from();

  /// Calls in flight.
  final int pendingRequests;

  /// Methods with a call in flight.
  final int trackedMethods;

  /// `service/method` of each method with a call in flight.
  final List<String> activeMethodKeys;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'pendingRequests': pendingRequests,
    'trackedMethods': trackedMethods,
    if (activeMethodKeys.isNotEmpty) 'activeMethodKeys': activeMethodKeys,
  };
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
