// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../../contracts/_index.dart';
import '../../core/_index.dart';
import '../../logger/_index.dart';

/// Predicate used to decide whether a routing rule applies.
typedef RpcRoutingCondition = bool Function(
    String? serviceName, String? methodPath, RpcContext? context);

/// Routing rule with a priority value.
typedef PrioritizedRoutingRule = ({
  IRpcTransport transport,
  String description,
  int priority,
  RpcRoutingCondition matches,
});

/// Proxy that routes RPC calls to transports using prioritized rules.
/// Extracts `serviceName` from the `x-route-service` header set by caller endpoints.
final class RpcTransportRouter implements IRpcTransport {
  /// All routing rules sorted by priority (descending).
  final List<PrioritizedRoutingRule> _routingRules = [];

  /// Stream ID manager.
  final RpcStreamIdManager _idManager;

  /// Controller for incoming messages.
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Maps client stream ID to the target transport.
  final Map<int, IRpcTransport> _streamTransports = {};

  /// Maps client stream ID to server stream ID.
  final Map<int, int> _clientToServerStreamMapping = {};

  /// Active response subscriptions per stream.
  final Map<int, StreamSubscription> _responseSubscriptions = {};

  /// Logger.
  final LogScope _logger;

  /// Close flag.
  bool _closed = false;

  RpcTransportRouter._({
    required List<PrioritizedRoutingRule> routingRules,
    LogScope? logger,
    int maxActiveStreams = 10000,
  })  : _idManager = RpcStreamIdManager(isClient: true), // Always client-side
        _logger = logger ?? LogScope.noop,
        _maxActiveStreams = maxActiveStreams {
    // Sort rules by priority (highest first).
    _routingRules.addAll(routingRules);
    _routingRules.sort((a, b) => b.priority.compareTo(a.priority));

    _logger.internal(
      'Transport Router initialized with ${_routingRules.length} rules:',
    );
    for (int i = 0; i < _routingRules.length; i++) {
      final rule = _routingRules[i];
      _logger.internal('  ${i + 1}. [P${rule.priority}] ${rule.description}');
    }
    _logger.internal('  - Role: client (router is always client-side)');
  }

  final int _maxActiveStreams;

  /// Creates a response subscription for a specific stream.
  void _subscribeToResponsesForStream(
    int clientStreamId,
    int serverStreamId,
    IRpcTransport transport,
  ) {
    _logger.internal(
      'Subscribing to responses: client[$clientStreamId] <- server[$serverStreamId] via $transport',
    );

    // Listen to incoming transport messages (responses arrive via incomingMessages).
    final subscription = transport.incomingMessages
        .where((message) => message.streamId == serverStreamId)
        .listen(
      (message) {
        _logger.internal(
          'Received response from transport: server[$serverStreamId] -> client[$clientStreamId], payload=${message.payload != null ? "present" : "absent"}, isEndOfStream=${message.isEndOfStream}',
        );

        // Core logic: forward responses with the correct stream ID.
        final redirectedMessage = RpcTransportMessage(
          payload: message.payload,
          metadata: message.metadata,
          isEndOfStream: message.isEndOfStream,
          methodPath: message.methodPath,
          streamId: clientStreamId, // Replace stream ID.
          // Keep zero-copy payload.
          directPayload: message.directPayload,
        );

        _logger.internal(
          'Forwarding response: server[$serverStreamId] -> client[$clientStreamId]',
        );
        _incomingController.add(redirectedMessage);

        // Cleanup is handled in onDone to avoid double cleanup.
      },
      onError: (error) {
        _logger.error(
          'Transport error in stream $serverStreamId',
          error: error,
        );
        // Cleanup is required on errors too.
        _cleanupStream(clientStreamId, serverStreamId);
      },
      onDone: () {
        _logger.internal(
          'Response stream completed for stream $serverStreamId',
        );
        _cleanupStream(clientStreamId, serverStreamId);
      },
    );

    _responseSubscriptions[clientStreamId] = subscription;

    _logger.internal(
      'Subscription created: client[$clientStreamId] -> server[$serverStreamId]',
    );
  }

  /// Cleans up resources for a completed stream and returns true if a client or server stream ID was released.
  bool _cleanupStream(int clientStreamId, int serverStreamId) {
    // Guard against double cleanup.
    if (!_streamTransports.containsKey(clientStreamId) &&
        !_clientToServerStreamMapping.containsKey(clientStreamId) &&
        !_responseSubscriptions.containsKey(clientStreamId)) {
      _logger.debug(
        'Cleanup skipped: client stream [$clientStreamId] already cleaned',
      );
      return false;
    }

    _logger.internal(
      'Starting cleanup: client[$clientStreamId] -> server[$serverStreamId]',
    );

    var clientIdReleased = false;
    try {
      clientIdReleased = _idManager.releaseId(clientStreamId);
      _logger.debug(
        'Client stream ID [$clientStreamId] release result: $clientIdReleased',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to release client stream ID [$clientStreamId]',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final transport = _streamTransports[clientStreamId];
    final mappedServerStreamId =
        _clientToServerStreamMapping[clientStreamId] ?? serverStreamId;

    var serverIdReleased = false;
    if (transport != null) {
      try {
        serverIdReleased = transport.releaseStreamId(mappedServerStreamId);
        _logger.debug(
          'Requested release for server stream [$mappedServerStreamId] on $transport: $serverIdReleased',
        );
      } catch (error, stackTrace) {
        _logger.error(
          'Failed to release server stream [$mappedServerStreamId] on transport $transport',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } else {
      _logger.debug(
        'Transport already removed for client stream [$clientStreamId] during cleanup',
      );
    }

    _streamTransports.remove(clientStreamId);
    _clientToServerStreamMapping.remove(clientStreamId);

    final subscription = _responseSubscriptions.remove(clientStreamId);
    if (subscription != null) {
      _logger.internal(
        'Cancelling response subscription for client[$clientStreamId]',
      );
      subscription.cancel();
    }

    _logger.internal(
      'Cleanup completed for stream: client[$clientStreamId] -> server[$serverStreamId]',
    );

    return clientIdReleased || serverIdReleased;
  }

  /// Extracts an RpcContext from message metadata.
  RpcContext? _extractContextFromMessage(RpcTransportMessage message) {
    if (message.metadata == null) return null;

    final headers = <String, String>{};
    for (final header in message.metadata!.headers) {
      if (!header.name.startsWith(':') &&
          header.name != RpcHeaders.contentType &&
          header.name != 'te') {
        headers[header.name] = header.value;
      }
    }

    return RpcContext.withHeaders(headers);
  }

  String _summarizeHeadersForLog(RpcContext? context) {
    if (context == null || context.headers.isEmpty) {
      return 'headers=0';
    }

    const redactedKeys = <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'x-api-key',
    };

    final keys = context.headers.keys.toList()..sort();
    final safeKeys = keys.take(24).map(
          (k) => redactedKeys.contains(k) ? '$k=<redacted>' : k,
        );
    final suffix = keys.length > 24 ? ', ...' : '';
    return 'headers=${keys.length} keys=[${safeKeys.join(', ')}$suffix]';
  }

  String _truncateForLog(String? value, {int max = 200}) {
    if (value == null) return 'null';
    value = value.replaceAll('\r', ' ').replaceAll('\n', ' ');
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…';
  }

  String _summarizeMetadataForLog(RpcMetadata metadata) {
    final names = metadata.headers.map((h) => h.name).toList()..sort();
    final shown = names.take(24);
    final suffix = names.length > 24 ? ', ...' : '';
    return 'headers=${names.length} names=[${shown.join(', ')}$suffix]';
  }

  /// Core routing logic selects a transport by rule priority.
  IRpcTransport _selectTransport(RpcTransportMessage message) {
    final context = _extractContextFromMessage(message);
    final methodPath = message.methodPath;
    final serviceName = _serviceNameFromMethodPath(methodPath) ??
        context?.getHeader('x-route-service');

    _logger.internal(
      'Routing for service="${_truncateForLog(serviceName)}", '
      'method="${_truncateForLog(methodPath)}"',
    );
    _logger.internal('Routing context: ${_summarizeHeadersForLog(context)}');

    // Evaluate rules in descending priority.
    for (final rule in _routingRules) {
      _logger.debug(
        'Checking rule [P${rule.priority}]: ${rule.description}',
      );

      if (rule.matches(serviceName, methodPath, context)) {
        _logger.internal(
          'Matched rule [P${rule.priority}]: ${rule.description}',
        );
        return rule.transport;
      }
    }

    throw RpcException(
      'No transport found for routing: service="$serviceName", method="$methodPath". '
      'Add a matching routing rule.',
    );
  }

  String? _serviceNameFromMethodPath(String? methodPath) {
    if (methodPath == null) return null;
    if (methodPath.isEmpty || methodPath.length > 512) return null;
    if (!methodPath.startsWith('/')) return null;
    final parts = methodPath.substring(1).split('/');
    if (parts.length != 2) return null;
    if (parts[0].isEmpty || parts[1].isEmpty) return null;
    return parts[0];
  }

  @override
  int createStream() {
    if (_closed) throw StateError('TransportRouter is closed');
    return _idManager.generateId();
  }

  @override
  bool releaseStreamId(int streamId) {
    // Clear all mappings for the given stream ID.
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId != null) {
      return _cleanupStream(streamId, serverStreamId);
    }
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');
    if (_streamTransports.length >= _maxActiveStreams &&
        !_streamTransports.containsKey(streamId)) {
      throw RpcException(
        'TransportRouter activeStreams limit reached: $_maxActiveStreams',
      );
    }

    _logger.internal(
      'Sending metadata: streamId=$streamId, endStream=$endStream',
    );
    _logger.internal(
      'Metadata method path: ${_truncateForLog(metadata.methodPath)}',
    );
    _logger.internal('Metadata: ${_summarizeMetadataForLog(metadata)}');

    // Build a temporary message for routing.
    final routingMessage = RpcTransportMessage(
      metadata: metadata,
      streamId: streamId,
      methodPath: metadata.methodPath,
      isEndOfStream: endStream,
    );

    _logger.internal('Selecting transport for routing...');

    // Select transport.
    final transport = _selectTransport(routingMessage);

    _logger.internal('Selected transport: $transport');

    // Create a new stream ID on the target transport.
    final serverStreamId = transport.createStream();

    _logger.internal(
      'Created stream IDs: client[$streamId] -> server[$serverStreamId]',
    );

    // Store all mappings.
    _streamTransports[streamId] = transport;
    _clientToServerStreamMapping[streamId] = serverStreamId;

    _logger.internal(
      'Stream ID mapping: client[$streamId] -> server[$serverStreamId]',
    );

    // Subscribe to responses for this stream.
    _logger.internal('Creating response subscription...');
    _subscribeToResponsesForStream(streamId, serverStreamId, transport);

    // Forward the call using the new stream ID. If the send fails, roll back
    // ALL state registered above so the stream slot does not leak.
    _logger.internal('Sending metadata to target transport...');
    try {
      await transport.sendMetadata(
        serverStreamId,
        metadata,
        endStream: endStream,
      );
    } catch (e) {
      _logger.internal('sendMetadata failed, rolling back stream state: $e');
      _streamTransports.remove(streamId);
      _clientToServerStreamMapping.remove(streamId);
      final subscription = _responseSubscriptions.remove(streamId);
      await subscription?.cancel();
      transport.releaseStreamId(serverStreamId);
      rethrow;
    }

    _logger.internal('sendMetadata completed successfully');
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');

    // Use the saved transport for this stream.
    final transport = _streamTransports[streamId];
    if (transport == null) {
      throw StateError(
        'Transport not found for stream $streamId. Metadata likely was not sent first.',
      );
    }

    // Resolve server stream ID.
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId == null) {
      throw StateError(
        'Server stream ID not found for client stream $streamId',
      );
    }

    await transport.sendMessage(serverStreamId, data, endStream: endStream);

    // Do not clean here; cleanup happens after END_STREAM response.
    // For unary calls, endStream=true marks send completion while response is pending.
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');

    // Use the saved transport for this stream.
    final transport = _streamTransports[streamId];
    if (transport == null) {
      throw StateError(
        'Transport not found for stream $streamId. Metadata likely was not sent first.',
      );
    }

    // Resolve server stream ID.
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId == null) {
      throw StateError(
        'Server stream ID not found for client stream $streamId',
      );
    }

    // Proxy zero-copy call to the target transport.
    await transport.sendDirectObject(
      serverStreamId,
      object,
      endStream: endStream,
    );
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;

    final transport = _streamTransports[streamId];
    final serverStreamId = _clientToServerStreamMapping[streamId];

    if (transport != null && serverStreamId != null) {
      await transport.finishSending(serverStreamId);
      // Mapping is cleared in _cleanupStream when END_STREAM arrives.
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport router is closed',
        details: {
          'closed': true,
          'routingRules': _routingRules.length,
          'activeStreams': _streamTransports.length,
        },
      );
    }

    final seenTransports = <IRpcTransport>{};
    final dependencyStatuses = <Map<String, Object?>>[];
    var aggregatedLevel = RpcHealthLevel.healthy;

    for (final rule in _routingRules) {
      final transport = rule.transport;
      if (!seenTransports.add(transport)) continue;

      RpcHealthStatus status;
      try {
        status = await transport.health();
      } catch (error, stackTrace) {
        _logger.error(
          'Failed to fetch health from transport ${transport.runtimeType}: $error',
          error: error,
          stackTrace: stackTrace,
        );
        status = RpcHealthStatus.unhealthy(
          component: transport.runtimeType.toString(),
          message: 'Health check failed: $error',
          details: {'error': error.toString()},
        );
      }

      if (status.level.severity > aggregatedLevel.severity) {
        aggregatedLevel = status.level;
      }

      dependencyStatuses.add({
        'component': status.component,
        'level': status.level.name,
        'message': status.message,
        'details': status.details,
      });
    }

    final message = aggregatedLevel == RpcHealthLevel.healthy
        ? 'Transport router ready'
        : 'Transport router degraded due to dependency state';

    return RpcHealthStatus(
      component: runtimeType.toString(),
      level: aggregatedLevel,
      message: message,
      details: {
        'closed': _closed,
        'routingRules': _routingRules.length,
        'activeStreams': _streamTransports.length,
        'dependencies': dependencyStatuses,
      },
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport router is closed',
        details: {
          'closed': true,
          'routingRules': _routingRules.length,
          'activeStreams': _streamTransports.length,
        },
      );
    }

    final seenTransports = <IRpcTransport>{};
    final dependencyStatuses = <Map<String, Object?>>[];
    var aggregatedLevel = RpcHealthLevel.healthy;

    for (final rule in _routingRules) {
      final transport = rule.transport;
      if (!seenTransports.add(transport)) continue;

      RpcHealthStatus status;
      try {
        status = await transport.reconnect();
      } catch (error, stackTrace) {
        _logger.error(
          'Failed to reconnect transport ${transport.runtimeType}: $error',
          error: error,
          stackTrace: stackTrace,
        );
        status = RpcHealthStatus.unhealthy(
          component: transport.runtimeType.toString(),
          message: 'Reconnect failed: $error',
          details: {'error': error.toString()},
        );
      }

      if (status.level.severity > aggregatedLevel.severity) {
        aggregatedLevel = status.level;
      }

      dependencyStatuses.add({
        'component': status.component,
        'level': status.level.name,
        'message': status.message,
        'details': status.details,
      });
    }

    final message = aggregatedLevel == RpcHealthLevel.healthy
        ? 'Transport router dependencies are ready'
        : 'Transport router dependencies reported issues during reconnect';

    return RpcHealthStatus(
      component: runtimeType.toString(),
      level: aggregatedLevel,
      message: message,
      details: {
        'closed': _closed,
        'routingRules': _routingRules.length,
        'activeStreams': _streamTransports.length,
        'dependencies': dependencyStatuses,
      },
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _logger.internal('Closing TransportRouter...');

    // Cancel all transport subscriptions.
    for (final subscription in _responseSubscriptions.values) {
      await subscription.cancel();
    }
    _responseSubscriptions.clear();

    // Close controller.
    await _incomingController.close();

    // Clear state.
    _streamTransports.clear();
    _clientToServerStreamMapping.clear();

    _logger.internal('TransportRouter closed');
  }

  /// Router statistics.
  Map<String, dynamic> get statistics => {
        'totalRules': _routingRules.length,
        'rulesByPriority': {
          for (final rule in _routingRules) rule.priority: rule.description,
        },
        'activeStreams': _streamTransports.length,
        'closed': _closed,
      };

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  /// Router supports zero-copy if any routed transport does.
  @override
  bool get supportsZeroCopy {
    return _routingRules.any((rule) => rule.transport.supportsZeroCopy);
  }
}

/// Builder for a prioritized Transport Router.
final class RpcTransportRouterBuilder {
  final List<PrioritizedRoutingRule> _routingRules = [];
  LogScope _logger = LogScope.noop;
  int _maxActiveStreams = 10000;

  /// Creates a client-side router builder (odd Stream IDs only).
  factory RpcTransportRouterBuilder.client() => RpcTransportRouterBuilder._();

  /// Default builder (always client-side).
  factory RpcTransportRouterBuilder() => RpcTransportRouterBuilder._();

  RpcTransportRouterBuilder._();

  /// Sets a logger.
  RpcTransportRouterBuilder logger(LogScope? logger) {
    _logger = logger ?? LogScope.noop;
    return this;
  }

  /// Sets the maximum number of concurrently active streams.
  RpcTransportRouterBuilder maxActiveStreams(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', 'Must be > 0');
    }
    _maxActiveStreams = value;
    return this;
  }

  /// Ensures the transport is client-side.
  void _validateTransportRole(IRpcTransport transport) {
    // Create a test stream and inspect its ID.
    late final int testStreamId;
    try {
      testStreamId = transport.createStream();
    } catch (e) {
      // If creation fails (transport closed?), skip with a warning.
      _logger.warning('Could not verify transport role: $e');
      return;
    }

    final isTransportClient = testStreamId.isOdd; // odd = client

    // Release the test stream.
    transport.releaseStreamId(testStreamId);

    // Router always requires client transports.
    if (!isTransportClient) {
      throw ArgumentError(
        'Invalid transport role: router requires client transports (odd Stream IDs), '
        'but a server transport was provided (Stream ID: $testStreamId).',
      );
    }
  }

  /// Routes a specific service to a transport.
  RpcTransportRouterBuilder routeCall({
    required String calledServiceName,
    required IRpcTransport toTransport,
    int priority = 50,
  }) {
    _validateTransportRole(toTransport);

    _routingRules.add((
      transport: toTransport,
      description: 'Service route: $calledServiceName',
      priority: priority,
      matches: (serviceName, methodPath, context) =>
          serviceName == calledServiceName,
    ));
    return this;
  }

  /// Adds a conditional routing rule.
  RpcTransportRouterBuilder routeWhen({
    required IRpcTransport toTransport,
    required RpcRoutingCondition whenCondition,
    int priority = 70,
    String description = 'Custom routing rule',
  }) {
    _validateTransportRole(toTransport);

    _routingRules.add((
      transport: toTransport,
      description: description,
      priority: priority,
      matches: whenCondition,
    ));
    return this;
  }

  /// Builds the router instance.
  RpcTransportRouter build() {
    if (_routingRules.isEmpty) {
      throw ArgumentError(
        'Transport Router requires at least one routing rule. '
        'Add rules via routeCall or routeWhen.',
      );
    }

    return RpcTransportRouter._(
      routingRules: _routingRules,
      logger: _logger,
      maxActiveStreams: _maxActiveStreams,
    );
  }
}
