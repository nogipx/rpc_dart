// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// WebSocket транспорт для RPC Dart
///
/// Включает:
/// - WebSocketBaseTransport - базовая реализация транспорта
/// - WebSocketCallerTransport - клиентская часть
/// - WebSocketResponderTransport - серверная часть
/// - ReconnectManager - менеджер переподключений (опционально)
library;

export 'websocket_base_transport.dart';
export 'websocket_caller_transport.dart';
export 'websocket_responder_transport.dart';

// Только нужные менеджеры
export 'reconnect_manager.dart';
