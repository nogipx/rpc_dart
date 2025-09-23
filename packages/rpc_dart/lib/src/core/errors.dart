// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Базовое исключение для RPC ядра.
///
/// Используется для сигнализации о внутренних ошибках уровня фреймворка,
/// таких как исчерпание доступных Stream ID или некорректная конфигурация.
class RpcException implements Exception {
  final String message;

  RpcException(this.message);

  @override
  String toString() => 'RpcException: $message';
}
