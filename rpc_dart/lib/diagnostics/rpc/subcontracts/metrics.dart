// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_contract.dart';

/// Контракт для отправки метрик различных типов
abstract class _RpcMetricsContract extends OldRpcServiceContract {
  // Константы для имен методов
  static const methodSendMetrics = 'sendMetrics';
  static const methodLatencyMetric = 'latencyMetric';
  static const methodStreamMetric = 'streamMetric';
  static const methodErrorMetric = 'errorMetric';
  static const methodResourceMetric = 'resourceMetric';

  _RpcMetricsContract() : super('metrics');

  @override
  void setup() {
    addUnaryRequestMethod<RpcMetricsList, RpcNull>(
      methodName: methodSendMetrics,
      handler: (metricsList) => sendMetrics(metricsList.metrics),
      argumentParser: RpcMetricsList.fromJson,
      responseParser: RpcNull.fromJson,
    );

    // Для метрик задержки - используем специализированный адаптер и парсер
    addUnaryRequestMethod<RpcMetric, RpcNull>(
      methodName: methodLatencyMetric,
      // Используем обертку для корректного приведения типа к RpcMetric<RpcLatencyMetric>
      handler: (metric) => latencyMetric(_ensureLatencyMetric(metric)),
      argumentParser: RpcMetric.fromJson,
      responseParser: RpcNull.fromJson,
    );

    // Для метрик стрима
    addUnaryRequestMethod<RpcMetric, RpcNull>(
      methodName: methodStreamMetric,
      handler: (metric) => streamMetric(_ensureStreamMetric(metric)),
      argumentParser: RpcMetric.fromJson,
      responseParser: RpcNull.fromJson,
    );

    // Для метрик ошибок
    addUnaryRequestMethod<RpcMetric, RpcNull>(
      methodName: methodErrorMetric,
      handler: (metric) => errorMetric(_ensureErrorMetric(metric)),
      argumentParser: RpcMetric.fromJson,
      responseParser: RpcNull.fromJson,
    );

    // Для метрик ресурсов
    addUnaryRequestMethod<RpcMetric, RpcNull>(
      methodName: methodResourceMetric,
      handler: (metric) => resourceMetric(_ensureResourceMetric(metric)),
      argumentParser: RpcMetric.fromJson,
      responseParser: RpcNull.fromJson,
    );

    super.setup();
  }

  // Вспомогательные методы для обеспечения правильных типов метрик

  // Проверяет и возвращает метрику задержки с правильным типом
  RpcMetric<RpcLatencyMetric> _ensureLatencyMetric(RpcMetric metric) {
    if (metric is RpcMetric<RpcLatencyMetric>) {
      return metric;
    } else if (metric.metricType == RpcMetricType.latency) {
      return RpcMetric<RpcLatencyMetric>(
        id: metric.id,
        timestamp: metric.timestamp,
        metricType: metric.metricType,
        clientId: metric.clientId,
        content: metric.content as RpcLatencyMetric,
      );
    }
    throw ArgumentError(
        'Неверный тип метрики: ожидался тип latency, получен ${metric.metricType}');
  }

  // Проверяет и возвращает метрику стрима с правильным типом
  RpcMetric<RpcStreamMetric> _ensureStreamMetric(RpcMetric metric) {
    if (metric is RpcMetric<RpcStreamMetric>) {
      return metric;
    } else if (metric.metricType == RpcMetricType.stream) {
      return RpcMetric<RpcStreamMetric>(
        id: metric.id,
        timestamp: metric.timestamp,
        metricType: metric.metricType,
        clientId: metric.clientId,
        content: metric.content as RpcStreamMetric,
      );
    }
    throw ArgumentError(
        'Неверный тип метрики: ожидался тип stream, получен ${metric.metricType}');
  }

  // Проверяет и возвращает метрику ошибки с правильным типом
  RpcMetric<RpcErrorMetric> _ensureErrorMetric(RpcMetric metric) {
    if (metric is RpcMetric<RpcErrorMetric>) {
      return metric;
    } else if (metric.metricType == RpcMetricType.error) {
      return RpcMetric<RpcErrorMetric>(
        id: metric.id,
        timestamp: metric.timestamp,
        metricType: metric.metricType,
        clientId: metric.clientId,
        content: metric.content as RpcErrorMetric,
      );
    }
    throw ArgumentError(
        'Неверный тип метрики: ожидался тип error, получен ${metric.metricType}');
  }

  // Проверяет и возвращает метрику ресурсов с правильным типом
  RpcMetric<RpcResourceMetric> _ensureResourceMetric(RpcMetric metric) {
    if (metric is RpcMetric<RpcResourceMetric>) {
      return metric;
    } else if (metric.metricType == RpcMetricType.resource) {
      return RpcMetric<RpcResourceMetric>(
        id: metric.id,
        timestamp: metric.timestamp,
        metricType: metric.metricType,
        clientId: metric.clientId,
        content: metric.content as RpcResourceMetric,
      );
    }
    throw ArgumentError(
        'Неверный тип метрики: ожидался тип resource, получен ${metric.metricType}');
  }

  /// Метод для отправки пакета метрик различного типа
  Future<RpcNull> sendMetrics(List<RpcMetric> metrics);

  /// Метод для отправки метрик задержки
  Future<RpcNull> latencyMetric(RpcMetric<RpcLatencyMetric> metric);

  /// Метод для отправки метрик стриминга
  Future<RpcNull> streamMetric(RpcMetric<RpcStreamMetric> metric);

  /// Метод для отправки метрик ошибок
  Future<RpcNull> errorMetric(RpcMetric<RpcErrorMetric> metric);

  /// Метод для отправки метрик ресурсов
  Future<RpcNull> resourceMetric(RpcMetric<RpcResourceMetric> metric);
}

// Клиентские реализации контрактов
class _MetricsClient extends _RpcMetricsContract {
  final RpcEndpoint _endpoint;

  _MetricsClient(this._endpoint);

  @override
  Future<RpcNull> sendMetrics(List<RpcMetric> metrics) {
    final metricsList = RpcMetricsList(metrics);
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: _RpcMetricsContract.methodSendMetrics,
        )
        .call(
          request: metricsList,
          responseParser: RpcNull.fromJson,
        );
  }

  @override
  Future<RpcNull> latencyMetric(RpcMetric<RpcLatencyMetric> metric) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: _RpcMetricsContract.methodLatencyMetric,
        )
        .call(
          request: metric,
          responseParser: RpcNull.fromJson,
        );
  }

  @override
  Future<RpcNull> streamMetric(RpcMetric<RpcStreamMetric> metric) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: _RpcMetricsContract.methodStreamMetric,
        )
        .call(
          request: metric,
          responseParser: RpcNull.fromJson,
        );
  }

  @override
  Future<RpcNull> errorMetric(RpcMetric<RpcErrorMetric> metric) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: _RpcMetricsContract.methodErrorMetric,
        )
        .call(
          request: metric,
          responseParser: RpcNull.fromJson,
        );
  }

  @override
  Future<RpcNull> resourceMetric(RpcMetric<RpcResourceMetric> metric) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: _RpcMetricsContract.methodResourceMetric,
        )
        .call(
          request: metric,
          responseParser: RpcNull.fromJson,
        );
  }
}
