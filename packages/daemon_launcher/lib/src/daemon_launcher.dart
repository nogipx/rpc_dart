import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'daemon_log.dart';
import 'pid_file_manager.dart';

/// Result of a daemon spawn attempt.
class DaemonLaunchResult {
  const DaemonLaunchResult({
    required this.pid,
    required this.confirmed,
    required this.stillRunning,
  });

  /// PID reported by the spawned process (or the parent observation fallback).
  final int pid;

  /// Whether the child confirmed startup by writing its PID file.
  final bool confirmed;

  /// Whether the process appeared to be alive when the launcher finished waiting.
  final bool stillRunning;

  bool get success => confirmed || stillRunning;
}

/// Launches background daemon processes and waits for startup confirmation.
class DaemonLauncher {
  DaemonLauncher({
    required this.pidFileManager,
    required this.logFilePath,
    Duration startupTimeout = const Duration(seconds: 20),
    Duration pollInterval = const Duration(milliseconds: 250),
    RpcLogger? logger,
  })  : _startupTimeout = startupTimeout,
        _pollInterval = pollInterval,
        _logger = logger ?? RpcLogger('DaemonLauncher');

  final PidFileManager pidFileManager;
  final String logFilePath;
  final Duration _startupTimeout;
  final Duration _pollInterval;
  final RpcLogger _logger;

  /// Spawns a detached process using [executableArgs] and waits for startup.
  Future<DaemonLaunchResult> launch({
    required List<String> executableArgs,
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      executableArgs,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: true,
      mode: ProcessStartMode.detached,
    );

    await DaemonLog.append(
      logFilePath,
      'Фоновый процесс запущен (PID ${process.pid}). Ожидание подтверждения...',
    );

    final readyPid = await _waitForPidFile();
    if (readyPid != null) {
      await DaemonLog.append(
        logFilePath,
        'Демон подтвердил запуск (PID $readyPid).',
      );
      return DaemonLaunchResult(
        pid: readyPid,
        confirmed: true,
        stillRunning: true,
      );
    }

    final stillAlive = pidFileManager.isProcessRunning(process.pid);
    if (!stillAlive) {
      _logger.error(
        'Detached process ${process.pid} terminated before writing PID file.',
      );
      await DaemonLog.append(
        logFilePath,
        'Процесс ${process.pid} завершился до записи PID файла.',
      );
      return DaemonLaunchResult(
        pid: process.pid,
        confirmed: false,
        stillRunning: false,
      );
    }

    await DaemonLog.append(
      logFilePath,
      'PID файл не появился вовремя. Процесс ${process.pid} всё ещё активен.',
    );
    return DaemonLaunchResult(
      pid: process.pid,
      confirmed: false,
      stillRunning: true,
    );
  }

  Future<int?> _waitForPidFile() async {
    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final pid = pidFileManager.readPidSync();
      if (pid != null) {
        return pid;
      }
      await Future.delayed(_pollInterval);
    }
    return null;
  }
}
