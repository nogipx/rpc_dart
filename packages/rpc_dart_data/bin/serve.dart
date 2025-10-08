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
  final verbose = args['verbose'] as bool;

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
    await server.start();
  } catch (error, stackTrace) {
    await logger.error(
      'Не удалось запустить HTTP/2 сервер: $error',
      error: error,
      stackTrace: stackTrace,
    );
    await repository.dispose();
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
