// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_logs.dart';

abstract interface class RpcLoggerSettings {
  static IRpcDiagnosticClient? _diagnostic;
  static IRpcDiagnosticClient? get diagnostic => _diagnostic;

  static RpcLoggerLevel _defaultMinLogLevel = RpcLoggerLevel.info;
  static RpcLoggerLevel get defaultMinLogLevel => _defaultMinLogLevel;

  static void setDefaultMinLogLevel(RpcLoggerLevel level) {
    _defaultMinLogLevel = level;
  }

  static void setDiagnostic(IRpcDiagnosticClient diagnostic) {
    _diagnostic = diagnostic;
  }

  static void removeDiagnostic() {
    _diagnostic = null;
  }

  static void setLoggerFactory(RpcLoggerFactory factory) {
    _RpcLoggerRegistry._factory = factory;
  }

  static void removeLogger(String loggerName) {
    _RpcLoggerRegistry.instance.remove(loggerName);
  }

  static void clearLoggers() {
    _RpcLoggerRegistry.instance.clear();
  }
}
