import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpointBase', () {
    test('health maps transport levels and includes debug label', () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        healthResult: RpcHealthStatus.reconnecting(component: 'transport'),
      );

      final endpoint = _TestEndpoint(
        transport: transport,
        debugLabel: 'dbg',
      );
      addTearDown(() async => endpoint.close());

      final report = await endpoint.health();

      expect(report.endpointStatus.level, RpcHealthLevel.reconnecting);
      expect(report.endpointStatus.details['debugLabel'], equals('dbg'));
      expect(
        report.endpointStatus.details['transportType'],
        equals('_ConfigurableTransport'),
      );
    });

    test('health is unhealthy when transport.health throws', () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        throwOnHealth: true,
      );

      final endpoint = _TestEndpoint(transport: transport);
      addTearDown(() async => endpoint.close());

      final report = await endpoint.health();

      expect(report.transportStatus?.level, RpcHealthLevel.unhealthy);
      expect(report.endpointStatus.level, RpcHealthLevel.unhealthy);
      expect(report.transportStatus?.details['isClosed'], isFalse);
    });

    test('health is closed when transport.health throws and transport closed',
        () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        isClosed: true,
        throwOnHealth: true,
      );

      final endpoint = _TestEndpoint(transport: transport);
      addTearDown(() async => endpoint.close());

      final report = await endpoint.health();

      expect(report.transportStatus?.level, RpcHealthLevel.closed);
      expect(report.endpointStatus.level, RpcHealthLevel.degraded);
      expect(report.transportStatus?.details['isClosed'], isTrue);
    });

    test('reconnect returns degraded when transport does not support reconnect',
        () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        throwUnsupportedOnReconnect: true,
      );

      final endpoint = _TestEndpoint(transport: transport);
      addTearDown(() async => endpoint.close());

      final report = await endpoint.reconnect();

      expect(report.transportStatus?.level, RpcHealthLevel.degraded);
      expect(report.transportStatus?.details['supported'], isFalse);
      expect(report.endpointStatus.level, RpcHealthLevel.degraded);
    });

    test('reconnect returns unhealthy when transport.reconnect throws',
        () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        throwOnReconnect: true,
      );

      final endpoint = _TestEndpoint(transport: transport);
      addTearDown(() async => endpoint.close());

      final report = await endpoint.reconnect();

      expect(report.transportStatus?.level, RpcHealthLevel.unhealthy);
      expect(report.endpointStatus.level, RpcHealthLevel.unhealthy);
    });

    test('close swallows transport.close error and deactivates endpoint',
        () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        throwOnClose: true,
      );

      final endpoint = _TestEndpoint(transport: transport);

      await endpoint.close();
      await endpoint.close();

      expect(endpoint.isActive, isFalse);
    });
  });
}

final class _ConfigurableTransport implements IRpcTransport {
  final bool _isClient;
  bool _isClosed;

  bool throwOnHealth;
  bool throwOnReconnect;
  bool throwUnsupportedOnReconnect;
  bool throwOnClose;

  RpcHealthStatus healthResult;
  RpcHealthStatus reconnectResult;

  _ConfigurableTransport({
    required bool isClient,
    bool isClosed = false,
    this.throwOnHealth = false,
    this.throwOnReconnect = false,
    this.throwUnsupportedOnReconnect = false,
    this.throwOnClose = false,
    RpcHealthStatus? healthResult,
    RpcHealthStatus? reconnectResult,
  })  : _isClient = isClient,
        _isClosed = isClosed,
        healthResult = healthResult ??
            RpcHealthStatus.healthy(component: '_ConfigurableTransport'),
        reconnectResult = reconnectResult ??
            RpcHealthStatus.healthy(component: '_ConfigurableTransport');

  @override
  bool get isClient => _isClient;

  @override
  bool get isClosed => _isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => 1;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('Zero-copy not supported');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      const Stream<RpcTransportMessage>.empty();

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((message) => message.streamId == streamId);

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _isClosed = true;
    if (throwOnClose) throw StateError('close failed');
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (throwOnHealth) throw StateError('health failed');
    return healthResult;
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (throwUnsupportedOnReconnect) {
      throw UnsupportedError('no reconnect');
    }
    if (throwOnReconnect) throw StateError('reconnect failed');
    return reconnectResult;
  }
}

base class _TestEndpoint extends RpcEndpointBase {
  final RpcLogger _logger = const _NoopLogger();

  _TestEndpoint({
    required super.transport,
    super.debugLabel,
  });

  @override
  RpcLogger get logger => _logger;
}

class _NoopLogger implements RpcLogger {
  final String _name;

  const _NoopLogger([this._name = 'TestLogger']);

  @override
  String get name => _name;

  @override
  RpcLogger child(String childName, {String? label}) => _NoopLogger(childName);

  Future<void> _complete() async {}

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> internal(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> debug(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> info(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> warning(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> error(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();

  @override
  Future<void> critical(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _complete();
}
