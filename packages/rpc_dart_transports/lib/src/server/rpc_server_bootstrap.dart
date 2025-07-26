// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_server_interface.dart';

const String _defaultVersion = '1.0.0';

/// 🚀 Универсальный фасад для запуска production-ready RPC серверов
///
/// Инкапсулирует всю сложность управления сервером:
/// - CLI парсинг с красивой справкой
/// - Daemon режим с PID файлами
/// - Graceful shutdown через сигналы
/// - Error handling с классификацией
/// - Логирование в файл/консоль
/// - Мониторинг и метрики
///
/// Пример использования:
/// ```dart
/// void main(List<String> args) async {
///   final bootstrap = RpcServerBootstrap(
///     appName: 'My RPC Server',
///     version: '1.0.0',
///     contracts: [MyServiceContract()],
///   );
///
///   await bootstrap.run(args);
/// }
/// ```
class RpcServerBootstrap {
  final String appName;
  final String version;
  final String description;
  final List<RpcResponderContract> contracts;
  final IRpcServer server;
  final RpcLogger? logger;

  // Внутренние компоненты
  late final _SignalHandler _signalHandler;
  late final _ErrorHandler _errorHandler;
  late final _ServerConfig _config;

  RpcServerBootstrap({
    required this.appName,
    this.version = _defaultVersion,
    this.description = '',
    required this.contracts,
    required this.server,
    this.logger,
  });

  /// Главный entry point - запускает сервер с full production обвязкой
  Future<void> run(List<String> arguments) async {
    runZonedGuarded<void>(
      () => _runWithErrorHandling(arguments),
      (error, stackTrace) => _handleGlobalError(error, stackTrace),
    );
  }

  /// Основная логика с обработкой ошибок
  Future<void> _runWithErrorHandling(List<String> arguments) async {
    try {
      // 1. Парсим аргументы
      final parser = _createArgParser();
      late final ArgResults args;

      try {
        args = parser.parse(arguments);
      } catch (e) {
        print('❌ Ошибка аргументов: $e\n');
        _printUsage(parser);
        exit(1);
      }

      // 2. Обрабатываем специальные команды
      if (args['help'] as bool) {
        _printUsage(parser);
        return;
      }

      if (args['version'] as bool) {
        print('🚀 $appName v$version');
        return;
      }

      // 3. Создаем конфигурацию
      _config = _ServerConfig.fromArgs(args);
      _config.validate();

      // 4. Инициализируем компоненты
      _errorHandler = _ErrorHandler(
        verbose: _config.verbose,
        isDaemon: _config.isDaemonChild,
        logFile: _config.logFile,
      );

      _signalHandler = _SignalHandler();

      // 5. Обрабатываем daemon команды
      if (_config.stopDaemon) {
        await _stopDaemon();
        return;
      }

      if (_config.statusDaemon) {
        await _statusDaemon();
        return;
      }

      if (_config.reloadDaemon) {
        await _reloadDaemon();
        return;
      }

      // 6. Демонизация если нужно
      if (_config.daemon && !_config.isDaemonChild) {
        await _daemonize(arguments);
        return; // Родительский процесс завершается
      }

      // 7. Настраиваем обработчики сигналов
      _setupSignalHandlers();

      // 8. Создаем и запускаем сервер
      await _startServer();

      // 9. Ждем сигнал завершения
      await _signalHandler._waitForShutdown();

      // 10. Graceful shutdown
      await _gracefulShutdown();
    } catch (e, stackTrace) {
      await _errorHandler.handleError(e, stackTrace);
      exit(1);
    }
  }

  /// Создает и запускает RPC сервер
  Future<void> _startServer() async {
    print('🚀 Запуск $appName v$version');
    print('📡 ${server.runtimeType} сервер на ${server.host}:${server.port}');

    if (contracts.isEmpty) {
      throw ArgumentError('Не указано ни одного RPC контракта');
    }

    // Контракты уже зарегистрированы в сервере при его создании
    // (например, через RpcHttp2Server.createWithContracts)

    await server.start();

    final contractNames = contracts.map((c) => c.serviceName).join(', ');
    print('✅ Сервер запущен! Контракты: $contractNames');

    if (_config.isDaemonChild) {
      await _logDaemonReady();
    } else {
      print('💡 Нажмите Ctrl+C для graceful shutdown');
    }
  }

  /// Настраивает обработчики сигналов
  void _setupSignalHandlers() {
    _signalHandler.initialize();

    if (_config.isDaemonChild) {
      _signalHandler.onReload = () async {
        await _logDaemonEvent('Configuration reload requested');
        print('🔄 Перезагрузка конфигурации...');
        // TODO: Реализовать перезагрузку контрактов
      };

      _signalHandler.onStats = () async {
        await _logDaemonEvent('Statistics requested');
        if (server.isRunning) {
          final stats = 'Активных соединений: ${server.endpoints.length}';
          await _logDaemonStats(stats);
          print('📊 $stats');
        }
      };

      _signalHandler.onToggleDebug = () async {
        await _logDaemonEvent('Debug mode toggle requested');
        print('🐛 Переключение debug режима...');
        // TODO: Реализовать переключение уровня логирования
      };
    }
  }

  /// Graceful shutdown с таймаутом
  Future<void> _gracefulShutdown() async {
    print('🔄 Graceful shutdown...');

    try {
      await server.stop().timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('⚠️ Graceful shutdown превысил 10 секунд');
          exit(1);
        },
      );
      print('✅ Сервер остановлен');
    } catch (e) {
      print('❌ Ошибка при остановке: $e');
      exit(1);
    }
  }

  /// Демонизирует процесс
  Future<void> _daemonize(List<String> originalArgs) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
          'Daemon режим поддерживается только на Linux/macOS');
    }

    print('🔄 Запуск в daemon режиме...');

    final pidFile = _config.defaultPidFile;
    final logFile = _config.defaultLogFile;

    // Проверяем что daemon не запущен
    await _checkExistingDaemon(pidFile);

    // Подготавливаем аргументы для дочернего процесса
    final childArgs = originalArgs.toList();
    childArgs.removeWhere((arg) => arg == '--daemon' || arg == '-d');
    childArgs.add('--_daemon-child');

    // Создаем detached процесс
    final process = await Process.start(
      Platform.resolvedExecutable,
      [Platform.script.toFilePath(), ...childArgs],
      mode: ProcessStartMode.detached,
    );

    // Проверяем что процесс запустился
    await Future.delayed(Duration(milliseconds: 1000));
    if (!_isProcessRunning(process.pid)) {
      throw Exception('Дочерний процесс не запустился');
    }

    // Сохраняем PID
    await File(pidFile).writeAsString('${process.pid}');

    print('✅ Daemon запущен с PID: ${process.pid}');
    print('📄 PID файл: $pidFile');
    print('📝 Логи: $logFile');
    print('💡 Используйте --status для проверки');

    exit(0);
  }

  /// Останавливает daemon
  Future<void> _stopDaemon() async {
    final pidFile = _config.defaultPidFile;

    if (!await File(pidFile).exists()) {
      print('❌ Daemon не запущен');
      exit(1);
    }

    final pid = int.parse(await File(pidFile).readAsString());

    if (!_isProcessRunning(pid)) {
      print('❌ Процесс не найден');
      await File(pidFile).delete();
      exit(1);
    }

    print('🛑 Остановка daemon PID: $pid');

    if (Process.killPid(pid, ProcessSignal.sigterm)) {
      // Ждем завершения
      for (int i = 0; i < 100; i++) {
        if (!_isProcessRunning(pid)) {
          await File(pidFile).delete();
          print('✅ Daemon остановлен');
          return;
        }
        await Future.delayed(Duration(milliseconds: 100));
      }

      // Принудительное завершение
      Process.killPid(pid, ProcessSignal.sigkill);
      await File(pidFile).delete();
      print('✅ Daemon принудительно остановлен');
    } else {
      print('❌ Не удалось остановить daemon');
      exit(1);
    }
  }

  /// Показывает статус daemon
  Future<void> _statusDaemon() async {
    final pidFile = _config.defaultPidFile;

    if (!await File(pidFile).exists()) {
      print('❌ Daemon не запущен');
      exit(1);
    }

    final pid = int.parse(await File(pidFile).readAsString());

    if (_isProcessRunning(pid)) {
      print('✅ Daemon запущен с PID: $pid');
      print('📄 PID файл: $pidFile');
      print('📝 Логи: ${_config.defaultLogFile}');
    } else {
      print('❌ Процесс не найден, удаляем PID файл');
      await File(pidFile).delete();
      exit(1);
    }
  }

  /// Перезагружает daemon
  Future<void> _reloadDaemon() async {
    final pidFile = _config.defaultPidFile;

    if (!await File(pidFile).exists()) {
      print('❌ Daemon не запущен');
      exit(1);
    }

    final pid = int.parse(await File(pidFile).readAsString());

    if (_isProcessRunning(pid)) {
      if (Process.killPid(pid, ProcessSignal.sighup)) {
        print('✅ Сигнал перезагрузки отправлен');
        await _logDaemonEvent('Reload signal sent');
      } else {
        print('❌ Не удалось отправить сигнал');
        exit(1);
      }
    } else {
      print('❌ Процесс не найден');
      exit(1);
    }
  }

  // === ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ ===

  /// Парсер аргументов
  ArgParser _createArgParser() {
    return ArgParser()
      ..addOption('host',
          abbr: 'h', defaultsTo: 'localhost', help: 'Хост сервера')
      ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'Порт сервера')
      ..addOption('log-level',
          allowed: ['debug', 'info', 'warning', 'error'], defaultsTo: 'info')
      ..addFlag('verbose', abbr: 'v', help: 'Подробный вывод')
      ..addFlag('quiet', abbr: 'q', help: 'Тихий режим')
      ..addOption('log-file', help: 'Файл логов для daemon режима')
      ..addFlag('daemon', abbr: 'd', help: 'Запуск в daemon режиме')
      ..addFlag('stop', help: 'Остановить daemon')
      ..addFlag('status', help: 'Статус daemon')
      ..addFlag('reload', help: 'Перезагрузить daemon')
      ..addFlag('_daemon-child', hide: true, help: 'Внутренний флаг')
      ..addOption('pid-file', help: 'PID файл для daemon')
      ..addFlag('help', help: 'Показать справку')
      ..addFlag('version', help: 'Показать версию');
  }

  /// Печатает справку
  void _printUsage(ArgParser parser) {
    print('🚀 $appName v$version');
    if (description.isNotEmpty) {
      print(description);
    }
    print('\nИспользование:');
    print('  dart run [файл] [опции]');
    print('\nОпции:');
    print(parser.usage);
    print('\nПримеры:');
    print('  dart run server.dart                    # Запуск сервера');
    print('  dart run server.dart -p 9090            # На порту 9090');
    print('  dart run server.dart --daemon            # В daemon режиме');
    print('  dart run server.dart --status            # Статус daemon');
  }

  /// Проверяет что daemon не запущен
  Future<void> _checkExistingDaemon(String pidFile) async {
    if (await File(pidFile).exists()) {
      final pid = int.parse(await File(pidFile).readAsString());
      if (_isProcessRunning(pid)) {
        throw Exception('Daemon уже запущен с PID: $pid');
      } else {
        await File(pidFile).delete();
      }
    }
  }

  /// Проверяет запущен ли процесс
  bool _isProcessRunning(int pid) {
    try {
      final result = Process.runSync('ps', ['-p', pid.toString()]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Логирует событие daemon
  Future<void> _logDaemonEvent(String event) async {
    if (_config.logFile == null) return;
    try {
      final timestamp = DateTime.now().toIso8601String();
      await File(_config.logFile!).writeAsString(
        '$timestamp: [INFO] $event\n',
        mode: FileMode.writeOnlyAppend,
      );
    } catch (e) {
      // Игнорируем ошибки логирования
    }
  }

  /// Логирует готовность daemon
  Future<void> _logDaemonReady() async {
    await _logDaemonEvent(
        '$appName daemon ready on ${_config.host}:${_config.port}');
  }

  /// Логирует статистику daemon
  Future<void> _logDaemonStats(String stats) async {
    await _logDaemonEvent('Statistics: $stats');
  }

  /// Обрабатывает глобальные ошибки
  Future<void> _handleGlobalError(Object error, StackTrace stackTrace) async {
    final errorHandler = _ErrorHandler(
      verbose: true,
      isDaemon: false,
    );
    await errorHandler.handleError(error, stackTrace);
    exit(1);
  }
}

// === ВНУТРЕННИЕ КЛАССЫ (упрощенные версии из bin/router/) ===

/// Конфигурация сервера
class _ServerConfig {
  final String host;
  final int port;
  final bool verbose;
  final bool quiet;
  final String? logFile;
  final bool daemon;
  final bool isDaemonChild;
  final bool stopDaemon;
  final bool statusDaemon;
  final bool reloadDaemon;
  final String? pidFile;

  const _ServerConfig({
    required this.host,
    required this.port,
    required this.verbose,
    required this.quiet,
    this.logFile,
    required this.daemon,
    required this.isDaemonChild,
    required this.stopDaemon,
    required this.statusDaemon,
    required this.reloadDaemon,
    this.pidFile,
  });

  static _ServerConfig fromArgs(ArgResults args) {
    return _ServerConfig(
      host: args['host'] as String,
      port: int.parse(args['port'] as String),
      verbose: args['verbose'] as bool,
      quiet: args['quiet'] as bool,
      logFile: args['log-file'] as String?,
      daemon: args['daemon'] as bool,
      isDaemonChild: args['_daemon-child'] as bool,
      stopDaemon: args['stop'] as bool,
      statusDaemon: args['status'] as bool,
      reloadDaemon: args['reload'] as bool,
      pidFile: args['pid-file'] as String?,
    );
  }

  void validate() {
    if (port < 1 || port > 65535) {
      throw ArgumentError('Порт должен быть от 1 до 65535');
    }
    if (quiet && verbose) {
      throw ArgumentError('Нельзя использовать quiet и verbose одновременно');
    }
  }

  String get defaultPidFile => pidFile ?? '/tmp/rpc_server.pid';
  String get defaultLogFile => logFile ?? '/tmp/rpc_server.log';
}

/// Обработчик сигналов
class _SignalHandler {
  final Completer<void> _shutdownCompleter = Completer<void>();
  bool _shutdownInitiated = false;

  void Function()? onReload;
  void Function()? onStats;
  void Function()? onToggleDebug;

  void initialize() {
    ProcessSignal.sigint.watch().listen(_handleSigint);
    ProcessSignal.sigterm.watch().listen(_handleSigterm);

    if (Platform.isLinux || Platform.isMacOS) {
      ProcessSignal.sighup.watch().listen(_handleSighup);
      ProcessSignal.sigusr1.watch().listen(_handleSigusr1);
      ProcessSignal.sigusr2.watch().listen(_handleSigusr2);
    }
  }

  Future<void> _waitForShutdown() async {
    await _shutdownCompleter.future;
  }

  void _handleSigint(ProcessSignal signal) {
    if (!_shutdownInitiated) {
      _shutdownInitiated = true;
      print('\n🛑 Получен SIGINT, graceful shutdown...');
      _shutdownCompleter.complete();
    } else {
      print('\n⚡ Принудительное завершение!');
      exit(130);
    }
  }

  void _handleSigterm(ProcessSignal signal) {
    if (!_shutdownInitiated) {
      _shutdownInitiated = true;
      print('\n🛑 Получен SIGTERM, graceful shutdown...');
      _shutdownCompleter.complete();
    }
  }

  void _handleSighup(ProcessSignal signal) {
    print('\n🔄 Получен SIGHUP, перезагрузка...');
    onReload?.call();
  }

  void _handleSigusr1(ProcessSignal signal) {
    print('\n📊 Получен SIGUSR1, статистика...');
    onStats?.call();
  }

  void _handleSigusr2(ProcessSignal signal) {
    print('\n🐛 Получен SIGUSR2, debug...');
    onToggleDebug?.call();
  }
}

/// Обработчик ошибок (упрощенная версия)
class _ErrorHandler {
  final bool verbose;
  final bool isDaemon;
  final String? logFile;

  const _ErrorHandler({
    required this.verbose,
    required this.isDaemon,
    this.logFile,
  });

  Future<void> handleError(dynamic error, StackTrace? stackTrace) async {
    final timestamp = DateTime.now().toIso8601String();
    final message = '🚨 ОШИБКА [$timestamp]: $error';

    if (verbose && stackTrace != null) {
      print('$message\n📍 Stack trace:\n$stackTrace');
    } else {
      print(message);
    }

    if (isDaemon && logFile != null) {
      try {
        await File(logFile!).writeAsString(
          '$message\n',
          mode: FileMode.writeOnlyAppend,
        );
      } catch (e) {
        stderr.writeln('Failed to log error: $e');
      }
    }
  }
}
