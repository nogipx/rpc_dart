import 'package:universal_io/io.dart';

/// Lightweight helper for writing daemon lifecycle messages into a shared log file.
class DaemonLog {
  const DaemonLog._();

  /// Appends [message] to the daemon log file with an ISO-8601 timestamp.
  static Future<void> append(String logFilePath, String message) async {
    try {
      final logFile = File(logFilePath);
      await logFile.parent.create(recursive: true);
      final timestamp = DateTime.now().toIso8601String();
      await logFile.writeAsString('[$timestamp] $message\n',
          mode: FileMode.append, flush: true);
    } on IOException {
      // Logging must never interrupt daemon startup flows.
    }
  }

  /// Initializes the daemon log by writing a banner line.
  static Future<void> initialize(String logFilePath, String projectName) async {
    await append(
        logFilePath, '=== Запуск демона для проекта "$projectName" ===');
  }
}
