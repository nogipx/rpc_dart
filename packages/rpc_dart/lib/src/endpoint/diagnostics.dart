// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Результат проверки состояния RPC эндпоинта.
final class RpcEndpointHealth {
  /// Снимок состояния самого эндпоинта.
  final RpcHealthStatus endpointStatus;

  /// Состояние зависимостей эндпоинта (как правило, транспорта).
  final Map<String, RpcHealthStatus> dependencies;

  /// Время формирования отчета.
  final DateTime timestamp;

  RpcEndpointHealth({
    required this.endpointStatus,
    Map<String, RpcHealthStatus>? dependencies,
    DateTime? timestamp,
  })  : dependencies = Map.unmodifiable(dependencies ?? const {}),
        timestamp = timestamp ?? DateTime.now();

  /// Возвращает true, если эндпоинт и все зависимости находятся в рабочем
  /// состоянии.
  bool get isHealthy =>
      endpointStatus.isHealthy &&
      dependencies.values.every((status) => status.isHealthy);

  /// Состояние основного транспорта эндпоинта (если присутствует).
  RpcHealthStatus? get transportStatus => dependencies['transport'];
}
