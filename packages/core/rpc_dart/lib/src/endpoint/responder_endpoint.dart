// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Server-side RPC endpoint that handles incoming requests.
///
/// [RpcPeerEndpoint] is one too: it serves calls the same way and can also
/// start them, so a server in peer mode lists its connections wherever a
/// responder is expected.
final class RpcResponderEndpoint extends RpcEndpointBase
    with RpcResponderPipelineMixin {
  @override
  LogScope _log;

  /// The scope [setLogController] logs under.
  final String _logScopeName;

  /// Whether to compress responses, in an encoding from the caller's
  /// `grpc-accept-encoding` with a codec registered for it. Off by default:
  /// registering a codec makes it available, not used.
  @override
  final bool compressionEnabled;

  /// Creates an [RpcResponderEndpoint] bound to the given transport.
  ///
  /// With [logController] the endpoint logs under the `rpc.responder` scope.
  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    LogController? logController,
    this.compressionEnabled = false,
  }) : _logScopeName = 'rpc.responder',
       _log = logController?.scope('rpc.responder') ?? LogScope.noop {
    _validateServerTransport();
  }

  /// For [RpcPeerEndpoint]: a transport of either role, and its own scope.
  RpcResponderEndpoint._peer({
    required super.transport,
    super.debugLabel,
    LogController? logController,
    required this.compressionEnabled,
  }) : _logScopeName = 'rpc.peer',
       _log = logController?.scope('rpc.peer') ?? LogScope.noop;

  /// Inject a [LogController] after construction.
  ///
  /// Used by the framework to wire [RpcAppConfig.logController] into
  /// endpoints that were created by transport servers without one.
  void setLogController(LogController controller) {
    _log = controller.scope(_logScopeName);
  }

  /// Which inbound messages enter the responder pipeline; null for all.
  bool Function(RpcTransportMessage message)? get _inboundFilter => null;

  /// All method registrations exported from all contracts.
  Map<String, RpcMethodRegistration<Object, Object>> get _registeredMethods =>
      _respRegistry.exportMethodRegistrations();

  @override
  RpcResponderEndpointMetrics collectEndpointMetrics() =>
      RpcResponderEndpointMetrics._from(
        _commonMetrics(),
        _collectResponderMetrics(),
      );

  /// Starts serving: the endpoint reads calls from the transport and
  /// dispatches them to the registered contracts.
  void start() {
    _log.internal('Starting RPC endpoint');
    _startResponderListening(messageFilter: _inboundFilter);
  }

  @override
  Future<void> _closeResources() => _closeResponderResources();

  /// Throws if [serviceName].[methodName] is not registered with [expectedType].
  void _validateMethodExists(
    String serviceName,
    String methodName,
    RpcMethodType expectedType,
  ) {
    final methodKey = '$serviceName.$methodName';
    final binding = _respRegistry.lookup(methodKey);

    if (binding == null) {
      // UNIMPLEMENTED is gRPC's answer for a method the server does not have.
      throw RpcStatusException(
        RpcStatus.unimplemented,
        'Method $methodKey is not registered',
      );
    }

    if (binding.type != expectedType) {
      // INTERNAL: the method exists, this side wired it up as the wrong shape.
      throw RpcStatusException(
        RpcStatus.internal,
        'Method $methodKey is registered as ${binding.type.name}, '
        'but expected ${expectedType.name}',
      );
    }
  }

  void _validateServerTransport() {
    // A third-party transport's getter may throw; that is reported, not fatal.
    final bool isClient;
    try {
      isClient = transport.isClient;
    } catch (error) {
      _log.warning('Failed to validate transport role: $error');
      return;
    }
    if (isClient) {
      throw ArgumentError(
        'CRITICAL ERROR: RpcResponderEndpoint requires SERVER transport!\n'
        'Received client transport (isClient: true).\n'
        'Server endpoints must use transports with even Stream IDs (2, 4, 6...).\n\n'
        'Correct usage:\n'
        '  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();\n'
        '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
        '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
        'INCORRECT:\n'
        '  final responderEndpoint = RpcResponderEndpoint(transport: clientTransport);\n',
      );
    }
    _log.internal('Transport validated: server (isClient: false)');
  }
}
