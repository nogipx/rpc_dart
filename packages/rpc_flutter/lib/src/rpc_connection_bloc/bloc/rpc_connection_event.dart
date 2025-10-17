part of 'rpc_connection_bloc.dart';

class RpcConnectionInitialData {
  final RpcCallerEndpoint? endpoint;
  final String? host;
  final int? port;

  const RpcConnectionInitialData({
    this.endpoint,
    this.host,
    this.port,
  });
}

@immutable
abstract class RpcConnectionEvent {
  const RpcConnectionEvent();
}

/// Запустить мониторинг состояния endpoint.
///
/// Параметры:
/// - endpoint: готовый RpcCallerEndpoint — если указан, BLoC будет использовать его и не будет создавать собственный транспорт.
/// - transport: если указан транспорт, BLoC использует его для создания RpcCallerEndpoint.
/// - host/port: если указан host (и порт), BLoC создаст транспорт (HTTP2 или WebSocket) и endpoint сам.
/// - interval: интервал проверок здоровья.
/// - timeout: таймаут на ответ от сервера.
class RpcConnectionStart extends RpcConnectionEvent {
  const RpcConnectionStart({
    this.interval,
    this.timeout,
    this.data,
  });

  final RpcConnectionInitialData? data;
  final Duration? interval;
  final Duration? timeout;
}

class RpcConnectionStop extends RpcConnectionEvent {
  const RpcConnectionStop();
}

class _RpcConnectionCheck extends RpcConnectionEvent {
  const _RpcConnectionCheck();
}

class _RpcConnectionReconnectRequested extends RpcConnectionEvent {
  const _RpcConnectionReconnectRequested();
}
