// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Транспорты для RPC Dart
library;

export 'package:isolate_manager/isolate_manager.dart'
    show isolateManagerCustomWorker;

// Экспорт транспортов
export 'src/adapters/secure/_index.dart';
export 'src/server/_index.dart';
export 'src/transports/_index.dart';
