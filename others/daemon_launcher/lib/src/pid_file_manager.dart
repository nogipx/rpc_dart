import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

/// Управляет PID-файлом для фонового процесса.
class PidFileManager {
  PidFileManager(String path) : _pidFile = File(path);

  final File _pidFile;
  final RpcLogger _logger = RpcLogger('PidFileManager');

  /// Читает PID из файла, если он существует и содержит корректное значение.
  int? readPidSync() {
    try {
      if (!_pidFile.existsSync()) {
        return null;
      }
      final contents = _pidFile.readAsStringSync().trim();
      if (contents.isEmpty) {
        return null;
      }
      return int.tryParse(contents);
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to read PID file ${_pidFile.path}: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Проверяет, активен ли процесс с указанным PID.
  bool isProcessRunning(int pid) {
    if (pid <= 0) {
      return false;
    }

    if (Platform.isLinux || Platform.isAndroid) {
      return Directory('/proc/$pid').existsSync();
    }

    if (Platform.isMacOS || Platform.isIOS) {
      return _checkWithPs(pid);
    }

    if (Platform.isWindows) {
      return _checkWithTasklist(pid);
    }

    return _checkWithPs(pid);
  }

  /// Записывает указанный PID в файл, создавая директории при необходимости.
  Future<void> writePid(int pid) async {
    try {
      await _pidFile.parent.create(recursive: true);
      await _pidFile.writeAsString('$pid\n', flush: true);
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to write PID file ${_pidFile.path}: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Удаляет PID-файл, если он существует.
  Future<void> remove() async {
    try {
      if (await _pidFile.exists()) {
        await _pidFile.delete();
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to remove PID file ${_pidFile.path}: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _checkWithPs(int pid) {
    try {
      final result = Process.runSync('ps', ['-p', '$pid']);
      if (result.exitCode != 0) {
        return false;
      }
      return result.stdout.toString().contains('$pid');
    } catch (_) {
      return false;
    }
  }

  bool _checkWithTasklist(int pid) {
    try {
      final result = Process.runSync(
          'tasklist',
          [
            '/FI',
            'PID eq $pid',
          ],
          stdoutEncoding: const SystemEncoding());
      if (result.exitCode != 0) {
        return false;
      }
      final output = result.stdout.toString().toLowerCase();
      return output.contains('pid') && output.contains(pid.toString());
    } catch (_) {
      return false;
    }
  }
}
