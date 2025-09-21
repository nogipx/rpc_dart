// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Уровень состояния компонента RPC.
///
/// Значения перечислены по возрастанию серьезности для удобного сравнения.
enum RpcHealthLevel {
  /// Компонент полностью работоспособен.
  healthy,

  /// Компонент выполняет переподключение либо ожидает внешние ресурсы,
  /// временно недоступен для работы, но процесс восстановления уже запущен.
  reconnecting,

  /// Компонент работает, но имеются ограничения (например, деградировавший
  /// транспорт или потеря некоторых возможностей).
  degraded,

  /// Компонент недоступен из-за ошибки.
  unhealthy,

  /// Компонент окончательно закрыт и не может быть использован.
  closed,
}

/// Снимок состояния компонента системы.
///
/// Используется как результат проверки health() и reconnect().
class RpcHealthStatus {
  /// Имя компонента, для которого сформирован статус.
  final String component;

  /// Текущий уровень состояния.
  final RpcHealthLevel level;

  /// Краткое описание состояния.
  final String message;

  /// Дополнительные диагностические данные.
  final Map<String, Object?> details;

  /// Время формирования снимка состояния.
  final DateTime timestamp;

  RpcHealthStatus({
    required this.component,
    required this.level,
    String? message,
    Map<String, Object?>? details,
    DateTime? timestamp,
  })  : message = message ?? '',
        details = Map.unmodifiable(details ?? const {}),
        timestamp = timestamp ?? DateTime.now();

  /// Возвращает true, если компонент находится в полностью работоспособном
  /// состоянии без деградации.
  bool get isHealthy => level == RpcHealthLevel.healthy;

  /// Создает статус для полностью работоспособного компонента.
  factory RpcHealthStatus.healthy({
    required String component,
    String message = 'Component healthy',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.healthy,
        message: message,
        details: details,
      );

  /// Создает статус для компонента в состоянии деградации.
  factory RpcHealthStatus.degraded({
    required String component,
    String message = 'Component degraded',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.degraded,
        message: message,
        details: details,
      );

  /// Создает статус для компонента, выполняющего переподключение.
  factory RpcHealthStatus.reconnecting({
    required String component,
    String message = 'Component reconnecting',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.reconnecting,
        message: message,
        details: details,
      );

  /// Создает статус для компонента с ошибкой.
  factory RpcHealthStatus.unhealthy({
    required String component,
    String message = 'Component unhealthy',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.unhealthy,
        message: message,
        details: details,
      );

  /// Создает статус для окончательно закрытого компонента.
  factory RpcHealthStatus.closed({
    required String component,
    String message = 'Component closed',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.closed,
        message: message,
        details: details,
      );
}

/// Расширение для сравнения серьезности уровней здоровья.
extension RpcHealthLevelSeverity on RpcHealthLevel {
  /// Целочисленная серьезность уровня. Чем больше значение, тем хуже состояние.
  int get severity => switch (this) {
        RpcHealthLevel.healthy => 0,
        RpcHealthLevel.reconnecting => 1,
        RpcHealthLevel.degraded => 2,
        RpcHealthLevel.unhealthy => 3,
        RpcHealthLevel.closed => 4,
      };
}
