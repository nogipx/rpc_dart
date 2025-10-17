import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

part 'rpc_connection_event.dart';
part 'rpc_connection_state.dart';

enum RpcTransportType { http2, webSocket, auto }

extension RpcHealthBlocX on BuildContext {
  RpcConnectionBloc get rpcHealthBloc => read<RpcConnectionBloc>();
}

/// Универсальный BLoC для мониторинга health любого RpcCallerEndpoint.
///
/// Start через RpcConnectionStart (можно передать endpoint, transport или host+port).
class RpcConnectionBloc extends Bloc<RpcConnectionEvent, RpcConnectionState> {
  final _log = RpcLogger('RpcConnectionBloc');
  final Duration _defaultInterval;
  final Duration _defaultTimeout;
  final RpcTransportType _transportType;

  RpcConnectionBloc({
    RpcTransportType transportType = RpcTransportType.auto,
    Duration defaultInterval = const Duration(seconds: 10),
    Duration defaultTimeout = const Duration(seconds: 3),
  })  : _defaultTimeout = defaultTimeout,
        _defaultInterval = defaultInterval,
        _transportType = transportType,
        super(RpcConnectionState.initial()) {
    on<RpcConnectionStart>(_onStart);
    on<RpcConnectionStop>(_onStop);
    on<_RpcConnectionCheck>(_onCheckHealth);
    on<_RpcConnectionReconnectRequested>(_onReconnectRequested);

    _log.debug(
      'RpcConnectionBloc created with interval=${_defaultInterval.inSeconds}s, timeout=${_defaultTimeout.inSeconds}s',
    );
  }

  // Таймер оставляем приватным — он не хранится в состоянии.
  Timer? _timer;

  Future<void> _onStart(
    RpcConnectionStart ev,
    Emitter<RpcConnectionState> emit,
  ) async {
    final initialEndpoint = ev.data?.endpoint;
    final initialHost = ev.data?.host;
    final initialPort = ev.data?.port;
    final initialInterval = ev.interval ?? _defaultInterval;
    final initialTimeout = ev.timeout ?? _defaultTimeout;

    _log.info(
      'Start requested: '
      'endpoint=$initialEndpoint, '
      'host=$initialHost, '
      'port=$initialPort, '
      'interval=${ev.interval}, '
      'timeout=${ev.timeout}',
    );
    await _stopInternal(emit);

    if (initialInterval == Duration.zero) {
      _log.warning('Interval cannot be zero, setting to 1 second');
      emit(RpcConnectionState.disconnected());
      return;
    }

    emit(
      RpcConnectionState.connecting(
        endpoint: initialEndpoint,
        ownsEndpoint: initialEndpoint == null,
        interval: initialInterval,
        timeout: initialTimeout,
      ),
    );

    try {
      // Создаём транспорт/endpoint если нужно
      if (initialEndpoint != null) {
        _log.debug('Using provided endpoint');
        emit(
          state.copyWith(
            endpoint: initialEndpoint,
            ownsEndpoint: false,
          ),
        );
        // используем переданный endpoint — ничего не создаём
      } else if (initialHost != null && initialPort != null) {
        final host = initialHost;
        final port = initialPort;
        _log.debug('Connecting transport to $host:$port (kIsWeb=$kIsWeb)');
        IRpcTransport transport;

        if (kIsWeb) {
          transport = RpcWebSocketCallerTransport.connect(
            Uri.parse('ws://$host:$port'),
          );
          _log.debug('Created WebSocket transport');
        } else {
          transport = switch (_transportType) {
            RpcTransportType.auto =>
              await RpcHttp2CallerTransport.connect(host: host, port: port),
            RpcTransportType.webSocket => RpcWebSocketCallerTransport.connect(
                Uri.parse('ws://$host:$port'),
              ),
            RpcTransportType.http2 =>
              await RpcHttp2CallerTransport.connect(host: host, port: port),
          };
          _log.debug('Created HTTP2 transport');
        }
        final endpoint = RpcCallerEndpoint(transport: transport)..start();
        emit(
          state.copyWith(
            endpoint: endpoint,
            ownsEndpoint: true,
          ),
        );
        _log.info('Endpoint created from host/port and started');
      } else {
        _log.warning(
          'Start called without endpoint, transport or host/port - moving to disconnected',
        );
        emit(RpcConnectionState.disconnected());
        return;
      }

      // стартуем периодическую проверку по интервалу из состояния
      _timer?.cancel();
      _timer = Timer.periodic(initialInterval, (_) {
        _log.debug('Periodic health check triggered');
        add(const _RpcConnectionCheck());
      });
      _log.debug(
        'Health check timer started with interval ${initialInterval.inSeconds}s',
      );

      // немедленная первая проверка
      add(const _RpcConnectionCheck());
      _log.debug('Immediate health check scheduled');
    } on Object catch (error, stackTrace) {
      _log.error(
        'Failed to start RpcConnectionBloc',
        error: error,
        stackTrace: stackTrace,
      );
      await _stopInternal(emit);
      emit(RpcConnectionState.disconnected());
    }
  }

  Future<void> _onStop(
    RpcConnectionStop ev,
    Emitter<RpcConnectionState> emit,
  ) async {
    _log.info('Stop requested');
    await _stopInternal(emit);
    emit(RpcConnectionState.disconnected());
  }

  Future<void> _onCheckHealth(
    _RpcConnectionCheck ev,
    Emitter<RpcConnectionState> emit,
  ) async {
    _log.debug('Health check event received');
    if (state.checking) {
      _log.debug('Skipping health check because one is already in progress');
      return;
    }

    emit(state.copyWith(checking: true));
    try {
      final endpoint = state.endpoint;
      if (endpoint == null) {
        _log.warning(
          'No endpoint available during health check - setting disconnected',
        );
        emit(RpcConnectionState.disconnected());
        return;
      }

      if (endpoint.transport.isClosed) {
        emit(RpcConnectionState.disconnected());
        return;
      }

      final healthy = await _callHealth(endpoint);
      if (healthy) {
        emit(RpcConnectionState.healthy(state));
      } else {
        emit(RpcConnectionState.unhealthy(state));
        _log.info('Health call result: ${healthy ? 'healthy' : 'unhealthy'}');
        if (!state.reconnecting) {
          _log.debug('Requesting reconnect because endpoint is unhealthy');
          add(const _RpcConnectionReconnectRequested());
        }
      }
    } on Object catch (e, stackTrace) {
      _log.error(
        'Unexpected error during health check',
        error: e,
        stackTrace: stackTrace,
      );
      // In case of unexpected errors, consider marking unhealthy so reconnect logic can run
      emit(RpcConnectionState.unhealthy(state));
      if (!state.reconnecting) {
        add(const _RpcConnectionReconnectRequested());
      }
    } finally {
      // выключаем флаг checking в любом случае
      emit(state.copyWith(checking: false));
      _log.debug('Health check finished, checking flag cleared');
    }
  }

  Future<void> _onReconnectRequested(
    _RpcConnectionReconnectRequested ev,
    Emitter<RpcConnectionState> emit,
  ) async {
    _log.info('Reconnect requested');
    if (state.reconnecting) {
      _log.debug('Already reconnecting - ignoring');
      return;
    }

    emit(
      state.copyWith(
          reconnecting: true, status: RpcConnectionHealthStatus.connecting),
    );
    try {
      final endpoint = state.endpoint;
      if (endpoint == null) {
        _log.warning(
          'No endpoint available when trying to reconnect - moving to disconnected',
        );
        emit(RpcConnectionState.disconnected());
        return;
      }

      try {
        _log.debug('Calling endpoint.reconnect()');
        final res = endpoint.reconnect();
        await res;
        _log.info('Endpoint.reconnect() completed, verifying health');
        final healthy = await _callHealth(endpoint);
        if (healthy) {
          _log.info('Reconnect succeeded and endpoint is healthy');
          emit(RpcConnectionState.healthy(state).copyWith(reconnecting: false));
        } else {
          _log.warning('Reconnect completed but endpoint still unhealthy');
          emit(
            RpcConnectionState.unhealthy(state).copyWith(reconnecting: false),
          );
        }
      } on Object catch (error, stackTrace) {
        _log.error('Reconnect failed', error: error, stackTrace: stackTrace);
        // если reconnect не удался — если владеем транспортом, закроем его, иначе пометим disconnected
        emit(RpcConnectionState.disconnected());
      }
    } finally {
      // сброс флага reconnecting в состоянии, если он всё ещё установлен
      if (state.reconnecting) {
        _log.debug('Clearing reconnecting flag');
        emit(state.copyWith(reconnecting: false));
      }
    }
  }

  Future<bool> _callHealth(RpcCallerEndpoint endpoint) async {
    try {
      final timeout = state.timeout ?? _defaultTimeout;
      _log.debug('Performing health() call with timeout ${timeout}s');
      await endpoint.ping();
      final health = await endpoint.health().timeout(timeout);
      _log.debug('Health response received: isHealthy=${health.isHealthy}');
      return health.isHealthy;
    } on Object catch (error, stackTrace) {
      _log.error(
        'Health call failed or timed out',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _stopInternal(Emitter<RpcConnectionState>? emit) async {
    _log.debug(
      'Stopping internal resources: cancelling timer and closing owned endpoint if any',
    );
    _timer?.cancel();
    _timer = null;

    final current = state;

    if (current.endpoint != null && current.ownsEndpoint) {
      try {
        _log.debug('Closing owned endpoint');
        await current.endpoint?.close();
        _log.info('Owned endpoint closed');
      } on Object catch (error, stackTrace) {
        _log.error(
          'Error while closing endpoint',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // сбросим состояние в initial
    emit?.call(RpcConnectionState.initial());
    _log.debug('State reset to initial');
  }

  @override
  Future<void> close() async {
    _log.info('Bloc close() called');
    _timer?.cancel();
    await _stopInternal(null);
    return super.close();
  }
}
