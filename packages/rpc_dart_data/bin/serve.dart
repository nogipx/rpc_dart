// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'host',
      abbr: 'H',
      defaultsTo: InternetAddress.anyIPv4.address,
      help: 'Адрес интерфейса, на котором будет слушать сервис.',
    )
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '8080',
      help: 'TCP-порт HTTP/2 сервера.',
    )
    ..addOption(
      'database',
      abbr: 'd',
      defaultsTo: 'data_service.sqlite',
      help: 'Путь до SQLite файла для Drift-хранилища.',
    )
    ..addOption(
      'pid-file',
      defaultsTo: 'data_service.pid',
      help: 'Путь до PID файла для режима демона.',
    )
    ..addFlag(
      'daemon',
      abbr: 'D',
      help:
          'Запустить сервис в фоне: создаёт дочерний процесс и отсоединяет его.',
      negatable: false,
    )
    ..addFlag(
      'daemon-child',
      hide: true,
      negatable: false,
      help: 'Внутренний флаг для дочернего процесса демона.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      help: 'Включить подробное логирование.',
      negatable: false,
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Показать справку по команде.',
      negatable: false,
    );

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on ArgParserException catch (error) {
    stderr.writeln('Ошибка разбора аргументов: ${error.message}');
    stderr.writeln(parser.usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  if (args['help'] as bool) {
    stdout
      ..writeln('HTTP/2 сервис данных на основе rpc_dart_data')
      ..writeln()
      ..writeln('Использование: dart run rpc_dart_data:serve [опции]')
      ..writeln(parser.usage);
    return;
  }

  final portValue = args['port'] as String;
  final port = int.tryParse(portValue);
  if (port == null || port <= 0 || port > 65535) {
    stderr.writeln('Некорректный порт: "$portValue"');
    exitCode = 64;
    return;
  }

  final host = args['host'] as String;
  final databasePath = args['database'] as String;
  final pidFilePath = args['pid-file'] as String;
  final daemonize = args['daemon'] as bool;
  final isDaemonChild = args['daemon-child'] as bool;
  final verbose = args['verbose'] as bool;

  if (daemonize && !isDaemonChild) {
    final childArgs = <String>[];
    for (final argument in args.arguments) {
      if (argument == '--daemon' ||
          argument == '-D' ||
          argument == '--daemon-child' ||
          argument.startsWith('--daemon=')) {
        continue;
      }
      childArgs.add(argument);
    }
    childArgs.add('--daemon-child');

    final executableArguments = <String>[
      ...Platform.executableArguments,
    ];

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

    executableArguments.addAll(childArgs);

    try {
      final process = await Process.start(
        Platform.resolvedExecutable,
        executableArguments,
        environment: Platform.environment,
        mode: ProcessStartMode.detached,
      );

      stdout.writeln(
        'Daemon процесса данных запущен (PID ${process.pid}). PID-файл: $pidFilePath',
      );
      return;
    } catch (error, stackTrace) {
      stderr
        ..writeln('Не удалось создать daemon процесса: $error')
        ..writeln(stackTrace);
      exitCode = 1;
      return;
    }
  }

  final minLevel = verbose ? RpcLoggerLevel.debug : RpcLoggerLevel.info;
  RpcLogger.setDefaultMinLogLevel(minLevel);
  final logger = RpcLogger('DataService');

  await logger.info(
    'Запуск сервиса данных на $host:$port (база: ${File(databasePath).path})',
  );

  final repository = DriftDataRepository(
    storage: DriftDataStorageAdapter.file(File(databasePath)),
  );

  final server = RpcHttp2Server(
    host: host,
    port: port,
    logger: logger,
    onEndpointCreated: (endpoint) {
      unawaited(logger.debug('Создание endpoint ${endpoint.debugLabel}'));
      endpoint.registerServiceContract(
        DataServiceResponder(
          repository: repository,
          disposeRepositoryOnClose: false,
        ),
      );
    },
    onConnectionOpened: (socket) {
      unawaited(
        logger.info(
          'Новое соединение: ${socket.remoteAddress.address}:${socket.remotePort}',
        ),
      );
    },
    onConnectionClosed: (socket) {
      unawaited(
        logger.info(
          'Соединение закрыто: ${socket.remoteAddress.address}:${socket.remotePort}',
        ),
      );
    },
    onConnectionError: (error, stackTrace) {
      unawaited(
        logger.error(
          'Ошибка соединения HTTP/2: $error',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    },
  );

  final shutdownCompleter = Completer<void>();
  var isShuttingDown = false;
  RandomAccessFile? pidFileHandle;
  File? pidFile;

  Future<void> releasePidFile() async {
    if (pidFileHandle == null) {
      return;
    }

    try {
      await pidFileHandle!.truncate(0);
      await pidFileHandle!.flush();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось очистить PID файл перед удалением: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await pidFileHandle!.unlock();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось освободить блокировку PID файла: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await pidFileHandle!.close();
    } catch (error, stackTrace) {
      await logger.warning(
        'Не удалось закрыть PID файл: $error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      pidFileHandle = null;
    }

    if (pidFile != null) {
      try {
        await pidFile!.delete();
      } catch (error, stackTrace) {
        await logger.warning(
          'Не удалось удалить PID файл: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }
      pidFile = null;
    }
  }

  Future<void> shutdown(String reason) async {
    if (isShuttingDown) {
      return;
    }
    isShuttingDown = true;

    await logger.info('Остановка сервиса ($reason)...');

    try {
      await server.stop();
    } catch (error, stackTrace) {
      await logger.error(
        'Ошибка при остановке HTTP/2 сервера: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await repository.dispose();
    } catch (error, stackTrace) {
      await logger.error(
        'Ошибка при закрытии репозитория: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }

    await releasePidFile();

    shutdownCompleter.complete();
  }

  StreamSubscription<ProcessSignal>? listenSignal(ProcessSignal signal) {
    try {
      return signal.watch().listen((_) {
        shutdown('получен сигнал ${signal.toString()}');
      });
    } catch (error) {
      unawaited(
        logger.warning('Сигнал ${signal.toString()} не поддерживается: $error'),
      );
      return null;
    }
  }

  final signalSubscriptions = <StreamSubscription<ProcessSignal>>[];

  if (!Platform.isWindows) {
    final sigtermSubscription = listenSignal(ProcessSignal.sigterm);
    if (sigtermSubscription != null) {
      signalSubscriptions.add(sigtermSubscription);
    }
  }

  final sigintSubscription = listenSignal(ProcessSignal.sigint);
  if (sigintSubscription != null) {
    signalSubscriptions.add(sigintSubscription);
  }

  try {
    pidFile = File(pidFilePath);
    await pidFile!.parent.create(recursive: true);
    pidFileHandle = await pidFile!.open(mode: FileMode.write);
    await pidFileHandle!.lock(FileLock.exclusive);
    await pidFileHandle!.setPosition(0);
    await pidFileHandle!.truncate(0);
    await pidFileHandle!.writeString('${ProcessInfo.currentPid}\n');
    await pidFileHandle!.flush();
    await logger.info('PID файл создан: ${pidFile!.path} (PID ${ProcessInfo.currentPid})');
  } catch (error, stackTrace) {
    await logger.error(
      'Не удалось создать или заблокировать PID файл "$pidFilePath": $error',
      error: error,
      stackTrace: stackTrace,
    );
    await repository.dispose();
    for (final subscription in signalSubscriptions) {
      await subscription.cancel();
    }
    exitCode = 74; // EX_IOERR
    return;
  }

  try {
    await server.start();
  } catch (error, stackTrace) {
    await logger.error(
      'Не удалось запустить HTTP/2 сервер: $error',
      error: error,
      stackTrace: stackTrace,
    );
    await repository.dispose();
    await releasePidFile();
    for (final subscription in signalSubscriptions) {
      await subscription.cancel();
    }
    exitCode = 1;
    return;
  }

  await logger.info('Сервис запущен и ожидает соединения...');

  await shutdownCompleter.future;

  for (final subscription in signalSubscriptions) {
    await subscription.cancel();
  }

  await logger.info('Сервис данных остановлен.');
}
