// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

class DaemonLaunchException implements Exception {
  const DaemonLaunchException(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('DaemonLaunchException: ')
      ..write(message);
    if (cause != null) {
      buffer
        ..write(' (cause: ')
        ..write(cause)
        ..write(')');
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    return buffer.toString();
  }
}

class PidFileException implements Exception {
  const PidFileException(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('PidFileException: ')
      ..write(message);
    if (cause != null) {
      buffer
        ..write(' (cause: ')
        ..write(cause)
        ..write(')');
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    return buffer.toString();
  }
}

class DaemonProcessManager {
  DaemonProcessManager({
    required this.logger,
    required this.pidFilePath,
    this.daemonFlag = '--daemon',
    this.daemonChildFlag = '--daemon-child',
    this.daemonShortFlag = '-D',
  });

  final RpcLogger logger;
  final String pidFilePath;
  final String daemonFlag;
  final String daemonChildFlag;
  final String? daemonShortFlag;

  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];
  RandomAccessFile? _pidFileHandle;
  File? _pidFile;

  Future<Process?> maybeLaunchDaemon({
    required bool daemonizeRequested,
    required bool isDaemonChild,
    required List<String> cliArguments,
    Map<String, String>? environment,
  }) async {
    if (!daemonizeRequested || isDaemonChild) {
      return null;
    }

    final sanitizedArguments = <String>[];
    for (final originalArgument in cliArguments) {
      final isDaemonLong =
          originalArgument == daemonFlag ||
          originalArgument.startsWith('$daemonFlag=');
      if (isDaemonLong) {
        continue;
      }

      final sanitizedShort = _sanitizeShortFlag(originalArgument);
      if (sanitizedShort == null) {
        continue;
      }

      final isDaemonChildArgument = sanitizedShort == daemonChildFlag ||
          sanitizedShort.startsWith('$daemonChildFlag=');
      if (isDaemonChildArgument) {
        continue;
      }

      sanitizedArguments.add(sanitizedShort);
    }
    sanitizedArguments.add(daemonChildFlag);

    final executableArguments = <String>[...Platform.executableArguments];

    final hasExplicitScript = executableArguments.any(
      (argument) =>
          argument.endsWith('.dart') || argument.startsWith('package:'),
    );

    if (!hasExplicitScript) {
      final scriptUri = Platform.script;
      String? scriptArgument;

      if (scriptUri.scheme == 'file') {
        final scriptPath = scriptUri.toFilePath();
        if (scriptPath != Platform.resolvedExecutable &&
            File(scriptPath).existsSync()) {
          scriptArgument = scriptPath;
        }
      } else if (scriptUri.scheme == 'package') {
        scriptArgument = scriptUri.toString();
      }

      if (scriptArgument != null) {
        executableArguments.add(scriptArgument);
      }
    }

    executableArguments.addAll(sanitizedArguments);

    try {
      return await Process.start(
        Platform.resolvedExecutable,
        executableArguments,
        environment: environment ?? Platform.environment,
        mode: ProcessStartMode.detached,
      );
    } catch (error, stackTrace) {
      throw DaemonLaunchException(
        'Не удалось создать daemon процесса',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> registerSignalHandlers(
    Future<void> Function(String reason) onSignal,
  ) async {
    StreamSubscription<ProcessSignal>? listenSignal(ProcessSignal signal) {
      try {
        return signal.watch().listen((_) {
          unawaited(
            onSignal('получен сигнал ${signal.toString()}').catchError(
              (error, stackTrace) async {
                await logger.error(
                  'Ошибка обработки сигнала ${signal.toString()}: $error',
                  error: error,
                  stackTrace: stackTrace,
                );
              },
            ),
          );
        });
      } catch (error) {
        unawaited(
          logger.warning('Сигнал ${signal.toString()} не поддерживается: $error'),
        );
        return null;
      }
    }

    if (!Platform.isWindows) {
      final sigtermSubscription = listenSignal(ProcessSignal.sigterm);
      if (sigtermSubscription != null) {
        _signalSubscriptions.add(sigtermSubscription);
      }
    }

    final sigintSubscription = listenSignal(ProcessSignal.sigint);
    if (sigintSubscription != null) {
      _signalSubscriptions.add(sigintSubscription);
    }
  }

  Future<void> disposeSignalHandlers() async {
    for (final subscription in _signalSubscriptions) {
      await subscription.cancel();
    }
    _signalSubscriptions.clear();
  }

  Future<void> createPidFile() async {
    final file = File(pidFilePath);
    RandomAccessFile? handle;
    try {
      await file.parent.create(recursive: true);
      handle = await file.open(mode: FileMode.write);
      await handle.lock(FileLock.exclusive);
      await handle.setPosition(0);
      await handle.truncate(0);
      await handle.writeString('${ProcessInfo.currentPid}\n');
      await handle.flush();
      _pidFile = file;
      _pidFileHandle = handle;
      await logger.info(
        'PID файл создан: ${file.path} (PID ${ProcessInfo.currentPid})',
      );
    } catch (error, stackTrace) {
      if (handle != null) {
        try {
          await handle.close();
        } catch (closeError, closeStackTrace) {
          unawaited(
            logger.warning(
              'Не удалось закрыть PID файл после ошибки: $closeError',
              error: closeError,
              stackTrace: closeStackTrace,
            ),
          );
        }
      }
      throw PidFileException(
        'Не удалось создать или заблокировать PID файл "$pidFilePath"',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> releasePidFile() async {
    final handle = _pidFileHandle;
    final file = _pidFile;

    if (handle == null || file == null) {
      return;
    }

    try {
      await handle.truncate(0);
      await handle.flush();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось очистить PID файл перед удалением: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await handle.unlock();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось освободить блокировку PID файла: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await handle.close();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось закрыть PID файл: $error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _pidFileHandle = null;
    }

    try {
      await file.delete();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось удалить PID файл: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    _pidFile = null;
  }

  String? _sanitizeShortFlag(String argument) {
    final shortFlag = daemonShortFlag;
    if (shortFlag == null) {
      return argument;
    }

    if (argument == shortFlag) {
      return null;
    }

    if (!argument.startsWith('-') || argument.startsWith('--')) {
      return argument;
    }

    if (shortFlag.length != 2 || !shortFlag.startsWith('-')) {
      return argument;
    }

    final shortChar = shortFlag[1];
    final buffer = StringBuffer('-');
    var hasOtherFlags = false;

    for (var i = 1; i < argument.length; i++) {
      final char = argument[i];
      if (char == shortChar) {
        continue;
      }
      hasOtherFlags = true;
      buffer.write(char);
    }

    if (!hasOtherFlags) {
      return null;
    }

    return buffer.toString();
  }
}
