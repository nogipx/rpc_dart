// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_logs.dart';

/// {@template rpc_logger_registry}
/// Реестр логгеров для RPC библиотеки
///
/// Позволяет регистрировать и получать экземпляры логгеров по имени.
/// Также предоставляет глобальный экземпляр для удобства.
/// {@endtemplate}
final class _RpcLoggerRegistry {
  /// Статический фабричный метод для создания нового логгера
  static RpcLoggerFactory? _factory;

  /// Глобальный экземпляр реестра
  static final _RpcLoggerRegistry instance = _RpcLoggerRegistry._();

  /// Карта зарегистрированных логгеров
  final Map<String, RpcLogger> _loggers = {};

  /// Создает новый реестр логгеров
  _RpcLoggerRegistry._();

  /// Получает логгер с указанным именем
  ///
  /// Если логгер с таким именем не найден, создает новый
  RpcLogger get(String name, {RpcLoggerColors? colors, String? label}) {
    if (_factory == null) {
      return _loggers[name] ??= DefaultRpcLogger(
        name,
        colors: colors ?? const RpcLoggerColors(),
        label: label,
      );
    }
    return _loggers[name] ??= _factory!(
      name,
      colors: colors ?? const RpcLoggerColors(),
      label: label,
    );
  }

  /// Удаляет логгер с указанным именем
  void remove(String name) {
    _loggers.remove(name);
  }

  /// Очищает все зарегистрированные логгеры
  void clear() {
    _loggers.clear();
  }
}
