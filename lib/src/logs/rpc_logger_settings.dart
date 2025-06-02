// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_logs.dart';

abstract interface class RpcLoggerSettings {
  static RpcLoggerLevel _defaultMinLogLevel = RpcLoggerLevel.info;
  static RpcLoggerLevel get defaultMinLogLevel => _defaultMinLogLevel;

  static void setDefaultMinLogLevel(RpcLoggerLevel level) {
    _defaultMinLogLevel = level;
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
