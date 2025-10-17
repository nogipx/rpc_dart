part of 'rpc_connection_bloc.dart';

@immutable
class RpcConnectionState {
  const RpcConnectionState({
    required this.status,
    this.interval,
    this.timeout,
    this.endpoint,
    this.ownsEndpoint = false,
    this.checking = false,
    this.reconnecting = false,
    this.lastHealthy,
    this.lastCheckedAt,
  });

  final RpcConnectionHealthStatus status;
  final RpcCallerEndpoint? endpoint;
  final bool ownsEndpoint;
  final bool checking;
  final bool reconnecting;
  final bool? lastHealthy;
  final DateTime? lastCheckedAt;
  final Duration? interval;
  final Duration? timeout;

  RpcConnectionState copyWith({
    RpcConnectionHealthStatus? status,
    RpcCallerEndpoint? endpoint,
    bool? ownsEndpoint,
    bool? checking,
    bool? reconnecting,
    bool? lastHealthy,
    DateTime? lastCheckedAt,
    Duration? interval,
    Duration? timeout,
  }) {
    return RpcConnectionState(
      status: status ?? this.status,
      endpoint: endpoint ?? this.endpoint,
      ownsEndpoint: ownsEndpoint ?? this.ownsEndpoint,
      checking: checking ?? this.checking,
      reconnecting: reconnecting ?? this.reconnecting,
      lastHealthy: lastHealthy ?? this.lastHealthy,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      interval: interval ?? this.interval,
      timeout: timeout ?? this.timeout,
    );
  }

  // Фабрики удобных состояний
  factory RpcConnectionState.initial() {
    return const RpcConnectionState(
      status: RpcConnectionHealthStatus.initial,
    );
  }

  factory RpcConnectionState.connecting({
    required Duration interval,
    required Duration timeout,
    RpcCallerEndpoint? endpoint,
    bool ownsEndpoint = false,
  }) =>
      RpcConnectionState(
        status: RpcConnectionHealthStatus.connecting,
        endpoint: endpoint,
        ownsEndpoint: ownsEndpoint,
        interval: interval,
        timeout: timeout,
      );

  factory RpcConnectionState.healthy(
    RpcConnectionState base, {
    bool healthy = true,
  }) =>
      base.copyWith(
        status: RpcConnectionHealthStatus.healthy,
        lastHealthy: healthy,
        lastCheckedAt: DateTime.now(),
      );

  factory RpcConnectionState.unhealthy(RpcConnectionState base) =>
      base.copyWith(
        status: RpcConnectionHealthStatus.unhealthy,
        lastHealthy: false,
        lastCheckedAt: DateTime.now(),
      );

  factory RpcConnectionState.disconnected() => RpcConnectionState.initial();
}

enum RpcConnectionHealthStatus {
  initial,
  connecting,
  healthy,
  unhealthy,
  disconnected
}
