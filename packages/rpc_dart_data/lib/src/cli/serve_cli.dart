// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:licensify/licensify.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

/// Настроечный раннер CLI-команды `serve`.
///
/// Вынесен в отдельный модуль, чтобы переиспользовать реализацию
/// одновременно для старого входа `dart run rpc_dart_data:serve` и для
/// нового command-runner интерфейса (`dart run rpc_dart_data`).
/// Через параметры конструктора можно изменить набор аргументов, логику
/// поднятия приложения и текстовые сообщения, чтобы использовать раннер для
/// других RPC-сервисов без дублирования инфраструктуры.
class ServeCli {
  ServeCli({
    IOSink? outSink,
    IOSink? errSink,
    String? helpHeader,
    String? usageLine,
    String? loggerName,
    void Function(ArgParser parser)? configureArguments,
    ServeCliApplicationBuilder? applicationBuilder,
    ServeCliStartupMessageBuilder? startupMessageBuilder,
  })  : _stdout = outSink ?? stdout,
        _stderr = errSink ?? stderr,
        _helpHeader = helpHeader ??
            'HTTP/2 сервис данных на основе rpc_dart_data',
        _usageLine = usageLine ??
            'Использование: dart run rpc_dart_data:serve [опции]',
        _loggerName = loggerName ?? 'DataService',
        _configureAdditionalParser =
            configureArguments ?? _configureDataServiceArguments,
        _applicationBuilder =
            applicationBuilder ?? _buildDataServiceApplication,
        _startupMessageBuilder =
            startupMessageBuilder ?? _defaultStartupMessage;

  final IOSink _stdout;
  final IOSink _stderr;
  final String _helpHeader;
  final String _usageLine;
  final String _loggerName;
  final void Function(ArgParser parser) _configureAdditionalParser;
  final ServeCliApplicationBuilder _applicationBuilder;
  final ServeCliStartupMessageBuilder _startupMessageBuilder;

  /// Накапливает в переданном [parser] все опции, используемые командой.
  void configureParser(ArgParser parser) {
    _configureCommonArguments(parser);
    _configureAdditionalParser(parser);
  }

  /// Запуск обработчика.
  /// Возвращает exit code (0 при успехе).
  Future<int> run(
    ArgResults args, {
    required String usage,
  }) async {
    final helpRequested = args['help'] as bool;
    if (helpRequested) {
      _stdout
        ..writeln(_helpHeader)
        ..writeln()
        ..writeln(_usageLine)
        ..writeln(usage);
      return 0;
    }

    final portValue = args['port'] as String;
    final port = int.tryParse(portValue);
    if (port == null || port <= 0 || port > 65535) {
      _stderr.writeln('Некорректный порт: "$portValue"');
      return 64;
    }

    final host = args['host'] as String;
    final pidFilePath = args['pid-file'] as String;
    final daemonize = args['daemon'] as bool;
    final isDaemonChild = args['daemon-child'] as bool;
    final verbose = args['verbose'] as bool;

    SqlCipherKey? sqlCipherKey;
    try {
      sqlCipherKey = _parseSqlCipherKey(args);
    } on FormatException catch (error) {
      _stderr.writeln('Ошибка настроек SQLCipher: ${error.message}');
      return 64;
    }

    SecureWrapRuntimeConfig? secureWrapConfig;
    try {
      secureWrapConfig = _parseSecureWrapConfig(args);
    } on FormatException catch (error) {
      _stderr.writeln('Ошибка настроек secure wrap: ${error.message}');
      return 64;
    } catch (error, stackTrace) {
      _stderr.writeln('Не удалось инициализировать secure wrap: $error');
      _stderr.writeln(stackTrace);
      return 64;
    }

    RelayRuntimeConfig? relayConfig;
    try {
      relayConfig = await _parseRelayConfig(args);
    } on FormatException catch (error) {
      _stderr.writeln('Ошибка настроек relay: ${error.message}');
      return 64;
    } catch (error, stackTrace) {
      _stderr.writeln('Не удалось подготовить подключение к relay: $error');
      _stderr.writeln(stackTrace);
      return 64;
    }

    final minLevel = verbose ? RpcLoggerLevel.debug : RpcLoggerLevel.info;
    RpcLogger.setDefaultMinLogLevel(minLevel);
    final logger = RpcLogger(_loggerName);

    final processManager = DaemonProcessManager(
      logger: logger,
      pidFilePath: pidFilePath,
    );

    final runtime = ServeCliRuntime(
      args: args,
      usage: usage,
      host: host,
      port: port,
      pidFilePath: pidFilePath,
      daemonize: daemonize,
      isDaemonChild: isDaemonChild,
      verbose: verbose,
      logger: logger,
      processManager: processManager,
      sqlCipherKey: sqlCipherKey,
      secureWrapConfig: secureWrapConfig,
      relayConfig: relayConfig,
      stdoutSink: _stdout,
      stderrSink: _stderr,
    );

    late final ServeCliApplication application;
    try {
      application = await _applicationBuilder(runtime);
    } on SqlCipherException catch (error, stackTrace) {
      _stderr.writeln('Ошибка инициализации SQLCipher: ${error.message}');
      await logger.error(
        'Не удалось подготовить приложение сервиса: ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
      return 64;
    } catch (error, stackTrace) {
      await logger.error(
        'Не удалось подготовить приложение сервиса: $error',
        error: error,
        stackTrace: stackTrace,
      );
      return 1;
    }

    final daemonResult = await _maybeLaunchDaemon(runtime);
    final daemonExitCode = daemonResult.exitCode;
    if (daemonExitCode != null) {
      await _disposeApplication(application, logger);
      return daemonExitCode;
    }

    final process = daemonResult.process;
    if (process != null) {
      _stdout.writeln(
        'Daemon процесса данных запущен (PID ${process.pid}). PID-файл: $pidFilePath',
      );
      await _disposeApplication(application, logger);
      return 0;
    }

    final startupMessage = _startupMessageBuilder(runtime);
    await logger.info(startupMessage);

    if (secureWrapConfig != null) {
      final details = <String>[
        'frame=${secureWrapConfig.transportConfig.frameFormat.name}'
      ];
      final transportId = secureWrapConfig.keyStore.transportId;
      if (transportId.isNotEmpty) {
        details.add('transportId=$transportId');
      }
      final padding = secureWrapConfig.transportConfig.paddingBlockSize;
      if (padding != null) {
        details.add(
            'padding=$padding/${secureWrapConfig.transportConfig.maxPaddingBlocks}');
      }
      await logger.info('Secure wrap включён (${details.join(', ')}).');
    }

    final server = RpcHttp2Server(
      host: host,
      port: port,
      logger: logger,
      onEndpointCreated: (endpoint) {
        unawaited(logger.debug('Создание endpoint ${endpoint.debugLabel}'));
        unawaited(
          application.registerEndpoint(endpoint).catchError(
            (error, stackTrace) => logger.error(
              'Не удалось настроить endpoint: $error',
              error: error,
              stackTrace: stackTrace,
            ),
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
            'Соединение закрыто',
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
      transportWrapper: secureWrapConfig != null
          ? (inner, socket) {
              final secureLogger = logger.child('SecureWrap');
              return SecureTransportAdapter.wrap(
                inner,
                keyStore: secureWrapConfig!.keyStore,
                config: secureWrapConfig.transportConfig,
                logger: secureLogger,
              );
            }
          : null,
    );

    final shutdownCompleter = Completer<void>();
    var isShuttingDown = false;
    StreamSubscription<TurnConnectRequest>? relayConnectSubscription;
    RpcTurnRelayPeer? relayPeer;

    Future<void> shutdown(String reason) async {
      if (isShuttingDown) {
        return;
      }
      isShuttingDown = true;

      await logger.info('Остановка сервиса ($reason)...');

      try {
        await relayConnectSubscription?.cancel();
      } catch (error, stackTrace) {
        await logger.error(
          'Не удалось закрыть подписку relay: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }

      try {
        await relayPeer?.close();
      } catch (error, stackTrace) {
        await logger.error(
          'Ошибка при остановке relay-подключения: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }

      try {
        await server.stop();
      } catch (error, stackTrace) {
        await logger.error(
          'Ошибка при остановке HTTP/2 сервера: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }

      await _disposeApplication(application, logger);

      await processManager.releasePidFile();

      shutdownCompleter.complete();
    }

    await processManager.registerSignalHandlers(shutdown);

    try {
      await processManager.createPidFile();
    } on PidFileException catch (error) {
      final cause = error.cause;
      await logger.error(
        cause != null ? '${error.message}: $cause' : error.message,
        error: cause,
        stackTrace: error.stackTrace,
      );
      await _disposeApplication(application, logger);
      await processManager.disposeSignalHandlers();
      return 74; // EX_IOERR
    }

    try {
      await server.start();
    } catch (error, stackTrace) {
      await logger.error(
        'Не удалось запустить HTTP/2 сервер: $error',
        error: error,
        stackTrace: stackTrace,
      );
      await _disposeApplication(application, logger);
      await processManager.releasePidFile();
      await processManager.disposeSignalHandlers();
      return 1;
    }

    await logger.info('Сервис запущен и ожидает соединения...');

    if (relayConfig != null) {
      final relayLogger = logger.child('Relay');
      final relayMetadata = <String, String>{...relayConfig.metadata};
      if (secureWrapConfig != null) {
        relayMetadata['secureWrap.enabled'] = 'true';
        final transportId = secureWrapConfig.keyStore.transportId;
        if (transportId.isNotEmpty) {
          relayMetadata['secureWrap.transportId'] = transportId;
        }
        relayMetadata['secureWrap.frameFormat'] =
            secureWrapConfig.transportConfig.frameFormat.name;
      }
      relayMetadata['transport'] = 'http2';
      relayMetadata['relay.transport'] = relayConfig.transportLabel;

      final publicationDescription =
          _composeRelayDescription(relayConfig.description, relayMetadata);

      InternetAddress? activeRelayPeerAddress;
      int? activeRelayPeerPort;

      try {
        final relayResponders = await application.createRelayResponders();
        relayPeer = await RpcTurnRelayPeer.connectToRelay(
          serverAddress: relayConfig.serverAddress,
          serverPort: relayConfig.serverPort,
          responderContracts: relayResponders,
          options: relayConfig.clientOptions,
        );

        await relayLogger.info(
          'Подключено к relay ${relayConfig.serverAddress.address}:${relayConfig.serverPort}. '
          'Назначенный адрес: ${relayPeer.relayAddress.address}:${relayPeer.relayPort}.',
        );

        if (relayConfig.publish) {
          await relayPeer.registerService(
            serviceId: relayConfig.serviceId,
            description: publicationDescription,
          );
          await relayLogger.info(
            'Сервис опубликован в relay как ${relayConfig.serviceId}.',
          );
          if (relayMetadata.isNotEmpty) {
            await relayLogger.debug(
              'Метаданные публикации: ${jsonEncode(relayMetadata)}',
            );
          }
        } else {
          await relayLogger.info('Публикация сервиса в relay отключена.');
        }

        relayConnectSubscription =
            relayPeer.connectRequests.listen((request) async {
          await relayLogger.info(
            'Получен запрос на подключение от ${request.peerAddress.address}:${request.peerPort}',
          );

          if (activeRelayPeerAddress != null &&
              (activeRelayPeerAddress!.address != request.peerAddress.address ||
                  activeRelayPeerPort != request.peerPort)) {
            await relayLogger.warning(
              'Уже активен пир ${activeRelayPeerAddress!.address}:$activeRelayPeerPort, '
              'игнорируем новый запрос.',
            );
            return;
          }

          if (activeRelayPeerAddress == null) {
            try {
              await relayPeer!.connectPeer(
                peerAddress: request.peerAddress,
                peerPort: request.peerPort,
                logger: relayLogger.child('Peer'),
              );
              activeRelayPeerAddress = request.peerAddress;
              activeRelayPeerPort = request.peerPort;
              await relayLogger.info(
                'Установлен канал с пиром ${request.peerAddress.address}:${request.peerPort}.',
              );
            } catch (error, stackTrace) {
              await relayLogger.error(
                'Ошибка подключения к пиру через relay: $error',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        });
      } catch (error, stackTrace) {
        await logger.error(
          'Не удалось инициализировать relay-подключение: $error',
          error: error,
          stackTrace: stackTrace,
        );
        await shutdown('relay initialization failed');
        await processManager.disposeSignalHandlers();
        return 1;
      }
    }

    await shutdownCompleter.future;

    await processManager.disposeSignalHandlers();

    await logger.info('Сервис остановлен.');

    return 0;
  }

  Future<ServeDaemonLaunchResult> _maybeLaunchDaemon(
    ServeCliRuntime runtime,
  ) async {
    try {
      final process = await runtime.processManager.maybeLaunchDaemon(
        daemonizeRequested: runtime.daemonize,
        isDaemonChild: runtime.isDaemonChild,
        cliArguments: runtime.args.arguments,
      );
      return ServeDaemonLaunchResult(process: process);
    } on DaemonLaunchException catch (error) {
      runtime.stderrSink.writeln(error.message);
      final cause = error.cause;
      if (cause != null) {
        runtime.stderrSink.writeln(cause);
      }
      final stackTrace = error.stackTrace;
      if (stackTrace != null) {
        runtime.stderrSink.writeln(stackTrace);
      }
      return const ServeDaemonLaunchResult(exitCode: 1);
    }
  }

  Future<void> _disposeApplication(
    ServeCliApplication application,
    RpcLogger logger,
  ) async {
    try {
      await application.dispose();
    } catch (error, stackTrace) {
      await logger.error(
        'Ошибка при закрытии приложения сервиса: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class ServeDaemonLaunchResult {
  const ServeDaemonLaunchResult({this.process, this.exitCode});

  final Process? process;
  final int? exitCode;
}

class ServeCliRuntime {
  ServeCliRuntime({
    required this.args,
    required this.usage,
    required this.host,
    required this.port,
    required this.pidFilePath,
    required this.daemonize,
    required this.isDaemonChild,
    required this.verbose,
    required this.logger,
    required this.processManager,
    required this.sqlCipherKey,
    required this.secureWrapConfig,
    required this.relayConfig,
    required this.stdoutSink,
    required this.stderrSink,
  });

  final ArgResults args;
  final String usage;
  final String host;
  final int port;
  final String pidFilePath;
  final bool daemonize;
  final bool isDaemonChild;
  final bool verbose;
  final RpcLogger logger;
  final DaemonProcessManager processManager;
  final SqlCipherKey? sqlCipherKey;
  final SecureWrapRuntimeConfig? secureWrapConfig;
  final RelayRuntimeConfig? relayConfig;
  final IOSink stdoutSink;
  final IOSink stderrSink;
}

typedef ServeCliApplicationBuilder =
    FutureOr<ServeCliApplication> Function(ServeCliRuntime runtime);

typedef ServeCliStartupMessageBuilder = String Function(
  ServeCliRuntime runtime,
);

class ServeCliApplication {
  ServeCliApplication({
    required FutureOr<void> Function(RpcServerEndpoint endpoint)
        registerEndpoint,
    FutureOr<List<RpcResponderContract>> Function()? createRelayResponders,
    FutureOr<void> Function()? onShutdown,
  })  : _registerEndpoint = registerEndpoint,
        _createRelayResponders = createRelayResponders,
        _onShutdown = onShutdown;

  final FutureOr<void> Function(RpcServerEndpoint endpoint) _registerEndpoint;
  final FutureOr<List<RpcResponderContract>> Function()?
      _createRelayResponders;
  final FutureOr<void> Function()? _onShutdown;

  Future<void> registerEndpoint(RpcServerEndpoint endpoint) async {
    await _registerEndpoint(endpoint);
  }

  Future<List<RpcResponderContract>> createRelayResponders() async {
    if (_createRelayResponders == null) {
      return const [];
    }
    final responders = await _createRelayResponders!.call();
    return responders;
  }

  Future<void> dispose() async {
    if (_onShutdown == null) {
      return;
    }
    await _onShutdown!();
  }
}

class SecureWrapRuntimeConfig {
  SecureWrapRuntimeConfig({
    required this.keyStore,
    required this.transportConfig,
  });

  final SecureTransportKeyStore keyStore;
  final SecureTransportConfig transportConfig;
}

class RelayRuntimeConfig {
  RelayRuntimeConfig({
    required this.serverAddress,
    required this.serverPort,
    required this.clientOptions,
    required this.serviceId,
    required this.publish,
    required this.metadata,
    required this.transportLabel,
    this.description,
  });

  final InternetAddress serverAddress;
  final int serverPort;
  final TurnRelayClientOptions clientOptions;
  final String serviceId;
  final bool publish;
  final Map<String, String> metadata;
  final String transportLabel;
  final String? description;
}

void _configureCommonArguments(ArgParser parser) {
  parser
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
      'secure-wrap',
      help:
          'Включить Licensify secure wrap поверх транспорта HTTP/2 (требуются PASERK ключи).',
      negatable: false,
    )
    ..addOption(
      'secure-wrap-private-key',
      help:
          'PASERK k4.secret приватного ключа Licensify. Ключ не читается из файлов и передаётся напрямую.',
    )
    ..addOption(
      'secure-wrap-peer-key',
      help: 'PASERK k4.public публичного ключа удалённого пира/клиента.',
    )
    ..addOption(
      'secure-wrap-transport-id',
      help: 'Необязательный идентификатор транспорта, публикуемый в relay.',
      defaultsTo: '',
    )
    ..addOption(
      'secure-wrap-handshake-timeout',
      help: 'Таймаут handshake secure wrap (например, 15s, 5000ms).',
      defaultsTo: '15s',
    )
    ..addOption(
      'secure-wrap-handshake-ttl',
      help: 'Время жизни handshake токена (например, 5m).',
      defaultsTo: '5m',
    )
    ..addOption(
      'secure-wrap-frame-format',
      allowed: SecureFrameFormat.values.map((format) => format.name),
      allowedHelp: {
        for (final format in SecureFrameFormat.values)
          format.name: format == SecureFrameFormat.verbose
              ? 'Совместимый вербозный формат (по умолчанию).'
              : 'Компактный формат с минимизацией полей.',
      },
      defaultsTo: SecureFrameFormat.verbose.name,
      help: 'Формат кадров secure wrap.',
    )
    ..addOption(
      'secure-wrap-padding-block-size',
      help: 'Размер блока паддинга (байт). 0 или пусто отключает паддинг.',
    )
    ..addOption(
      'secure-wrap-max-padding-blocks',
      defaultsTo: '3',
      help: 'Максимальное количество блоков паддинга.',
    )
    ..addFlag(
      'secure-wrap-remove-transport-id',
      help:
          'Удалять поле transportId из кадров (актуально для compact формата).',
      negatable: false,
    )
    ..addFlag(
      'secure-wrap-remove-protocol',
      help: 'Удалять поле protocol из кадров (актуально для compact формата).',
      negatable: false,
    )
    ..addOption(
      'secure-wrap-pending-handshake-limit',
      defaultsTo: '16',
      help: 'Лимит буфера сообщений до завершения secure handshake.',
    )
    ..addFlag(
      'relay',
      help: 'Подключить сервис к TURN relay и (по умолчанию) опубликовать его.',
      negatable: false,
    )
    ..addOption(
      'relay-host',
      help:
          'Адрес TURN relay (может быть IP или DNS). Обязателен при включенном relay.',
    )
    ..addOption(
      'relay-port',
      defaultsTo: '3478',
      help: 'TCP-порт TURN relay.',
    )
    ..addOption(
      'relay-service-id',
      defaultsTo: 'rpc-data-service',
      help: 'Идентификатор сервиса при публикации в relay.',
    )
    ..addOption(
      'relay-description',
      help: 'Человеко-читаемое описание сервиса для каталога relay.',
    )
    ..addMultiOption(
      'relay-metadata',
      help:
          'Дополнительные метаданные публикации в формате ключ=значение. Значение сериализуется в JSON и передается в описании.',
      valueHelp: 'key=value',
    )
    ..addOption(
      'relay-local-address',
      help: 'Локальный адрес TCP-клиента при подключении к relay.',
    )
    ..addOption(
      'relay-local-port',
      defaultsTo: '0',
      help: 'Локальный TCP-порт клиента (0 = выбрать автоматически).',
    )
    ..addOption(
      'relay-request-timeout',
      defaultsTo: '5s',
      help: 'Таймаут TURN запросов Allocate/Refresh/Permission.',
    )
    ..addOption(
      'relay-allocation-lifetime',
      help: 'Желаемое время жизни allocation (например, 5m).',
    )
    ..addOption(
      'relay-allocation-margin',
      defaultsTo: '30s',
      help: 'Запас по времени перед обновлением allocation.',
    )
    ..addOption(
      'relay-permission-lifetime',
      defaultsTo: '5m',
      help: 'Ожидаемое время жизни TURN permission.',
    )
    ..addOption(
      'relay-permission-margin',
      defaultsTo: '30s',
      help: 'Запас по времени перед обновлением permission.',
    )
    ..addFlag(
      'relay-auto-permission',
      defaultsTo: true,
      help: 'Автоматически создавать TURN permissions при отправке данных.',
    )
    ..addOption(
      'relay-transport',
      defaultsTo: 'udp',
      allowed: const ['udp', 'tcp'],
      help: 'Протокол для relay (udp или tcp).',
    )
    ..addFlag(
      'relay-publish',
      defaultsTo: true,
      help: 'Публиковать сервис в каталоге relay (можно отключить).',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Показать справку по команде.',
      negatable: false,
    );
}

void _configureDataServiceArguments(ArgParser parser) {
  parser.addOption(
    'database',
    abbr: 'd',
    defaultsTo: 'data_service.sqlite',
    help: 'Путь до SQLite файла для Drift-хранилища.',
  );
  parser.addOption(
    'database-key',
    help:
        'PASERK k4.local ключ SQLCipher (XChaCha20). Активирует шифрование файла.',
  );
}

ServeCliApplication _buildDataServiceApplication(ServeCliRuntime runtime) {
  final databasePath = runtime.args['database'] as String;
  final repository = DriftDataRepository(
    storage: DriftDataStorageAdapter.file(
      File(databasePath),
      sqlCipherKey: runtime.sqlCipherKey,
    ),
  );

  return ServeCliApplication(
    registerEndpoint: (endpoint) {
      endpoint.registerServiceContract(
        DataServiceResponder(
          repository: repository,
          disposeRepositoryOnClose: false,
        ),
      );
    },
    createRelayResponders: () async => [
      DataServiceResponder(
        repository: repository,
        disposeRepositoryOnClose: false,
      ),
    ],
    onShutdown: () => repository.dispose(),
  );
}

String _defaultStartupMessage(ServeCliRuntime runtime) {
  final databasePath = runtime.args['database'] as String?;
  final databaseInfo =
      databasePath != null ? ' (база: ${File(databasePath).path})' : '';
  final cipherInfo = runtime.sqlCipherKey != null ? ' + SQLCipher' : '';
  return 'Запуск сервиса данных на ${runtime.host}:${runtime.port}$databaseInfo$cipherInfo';
}

SqlCipherKey? _parseSqlCipherKey(ArgResults args) {
  final raw = (args['database-key'] as String?)?.trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return SqlCipherKey.fromPaserk(paserk: raw);
}

SecureWrapRuntimeConfig? _parseSecureWrapConfig(ArgResults args) {
  final enabled = args['secure-wrap'] as bool;
  if (!enabled) {
    return null;
  }

  final privateKeyRaw = (args['secure-wrap-private-key'] as String?)?.trim();
  if (privateKeyRaw == null || privateKeyRaw.isEmpty) {
    throw const FormatException(
      'Для включения secure wrap укажите PASERK приватный ключ (--secure-wrap-private-key).',
    );
  }

  final peerKeyRaw = (args['secure-wrap-peer-key'] as String?)?.trim();
  if (peerKeyRaw == null || peerKeyRaw.isEmpty) {
    throw const FormatException(
      'Для включения secure wrap укажите PASERK публичный ключ пира (--secure-wrap-peer-key).',
    );
  }

  final transportId =
      (args['secure-wrap-transport-id'] as String?)?.trim() ?? '';

  LicensifyPrivateKey privateKey;
  try {
    privateKey = LicensifyPrivateKey.fromPaserkSecret(paserk: privateKeyRaw);
  } catch (error) {
    throw FormatException(
        'Не удалось импортировать приватный ключ из PASERK: $error');
  }

  LicensifyPublicKey peerPublicKey;
  try {
    peerPublicKey = LicensifyPublicKey.fromPaserk(paserk: peerKeyRaw);
  } catch (error) {
    throw FormatException(
        'Не удалось импортировать публичный ключ из PASERK: $error');
  }

  final handshakeTimeout = _parseDurationOption(
    args['secure-wrap-handshake-timeout'] as String?,
    '--secure-wrap-handshake-timeout',
    defaultValue: const Duration(seconds: 15),
  );
  final handshakeTtl = _parseDurationOption(
    args['secure-wrap-handshake-ttl'] as String?,
    '--secure-wrap-handshake-ttl',
    defaultValue: const Duration(minutes: 5),
  );

  final frameFormatRaw = args['secure-wrap-frame-format'] as String?;
  final frameFormat = SecureFrameFormat.values.firstWhere(
    (format) => format.name == frameFormatRaw,
    orElse: () => SecureFrameFormat.verbose,
  );

  final paddingBlockSize = _parseOptionalInt(
    args['secure-wrap-padding-block-size'] as String?,
    optionName: '--secure-wrap-padding-block-size',
    minValue: 0,
  );
  final maxPaddingBlocks = _parseIntOption(
    args['secure-wrap-max-padding-blocks'] as String?,
    '--secure-wrap-max-padding-blocks',
    minValue: 0,
  );
  final pendingHandshakeLimit = _parseIntOption(
    args['secure-wrap-pending-handshake-limit'] as String?,
    '--secure-wrap-pending-handshake-limit',
    minValue: 0,
  );

  final removeTransportId = args['secure-wrap-remove-transport-id'] as bool;
  final removeProtocol = args['secure-wrap-remove-protocol'] as bool;

  return SecureWrapRuntimeConfig(
    keyStore: SecureTransportKeyStore(
      privateKey: privateKey,
      peerPublicKey: peerPublicKey,
      transportId: transportId,
    ),
    transportConfig: SecureTransportConfig(
      handshakeTimeout: handshakeTimeout,
      handshakeTokenTtl: handshakeTtl,
      frameFormat: frameFormat,
      paddingBlockSize: paddingBlockSize == null || paddingBlockSize == 0
          ? null
          : paddingBlockSize,
      maxPaddingBlocks: maxPaddingBlocks,
      removeTransportId: removeTransportId,
      removeProtocol: removeProtocol,
      pendingHandshakeMessageLimit: pendingHandshakeLimit,
    ),
  );
}

Future<RelayRuntimeConfig?> _parseRelayConfig(ArgResults args) async {
  final enabled = args['relay'] as bool;
  if (!enabled) {
    return null;
  }

  final hostRaw = (args['relay-host'] as String?)?.trim();
  if (hostRaw == null || hostRaw.isEmpty) {
    throw const FormatException(
      'Для включения relay укажите адрес сервера (--relay-host).',
    );
  }

  final serverAddress = await _resolveAddress(hostRaw, '--relay-host');

  final port = _parseIntOption(
    args['relay-port'] as String?,
    '--relay-port',
    minValue: 1,
    maxValue: 65535,
  );

  final localPort = _parseIntOption(
    args['relay-local-port'] as String?,
    '--relay-local-port',
    minValue: 0,
    maxValue: 65535,
  );

  final localAddressRaw = (args['relay-local-address'] as String?)?.trim();
  InternetAddress? localAddress;
  if (localAddressRaw != null && localAddressRaw.isNotEmpty) {
    localAddress =
        await _resolveAddress(localAddressRaw, '--relay-local-address');
  }

  final requestTimeout = _parseDurationOption(
    args['relay-request-timeout'] as String?,
    '--relay-request-timeout',
    defaultValue: const Duration(seconds: 5),
  );
  final allocationLifetime = _parseOptionalDuration(
    args['relay-allocation-lifetime'] as String?,
    '--relay-allocation-lifetime',
  );
  final allocationMargin = _parseDurationOption(
    args['relay-allocation-margin'] as String?,
    '--relay-allocation-margin',
    defaultValue: const Duration(seconds: 30),
  );
  final permissionLifetime = _parseDurationOption(
    args['relay-permission-lifetime'] as String?,
    '--relay-permission-lifetime',
    defaultValue: const Duration(minutes: 5),
  );
  final permissionMargin = _parseDurationOption(
    args['relay-permission-margin'] as String?,
    '--relay-permission-margin',
    defaultValue: const Duration(seconds: 30),
  );

  final transportRaw = (args['relay-transport'] as String?)?.toLowerCase();
  final relayTransport = transportRaw == 'tcp'
      ? TurnTransport.tcp
      : TurnTransport.udp;

  final publish = args['relay-publish'] as bool;
  final autoPermission = args['relay-auto-permission'] as bool;

  final metadataEntries = args['relay-metadata'] as List<String>;
  final metadata = _parseKeyValueMetadata(
    metadataEntries,
    '--relay-metadata',
  );

  final description = (args['relay-description'] as String?)?.trim();

  return RelayRuntimeConfig(
    serverAddress: serverAddress,
    serverPort: port,
    clientOptions: TurnRelayClientOptions(
      localAddress: localAddress,
      localPort: localPort,
      relayTransport: relayTransport,
      publishService: publish,
      serviceId: args['relay-service-id'] as String,
      requestTimeout: requestTimeout,
      allocationLifetime: allocationLifetime,
      allocationMargin: allocationMargin,
      permissionLifetime: permissionLifetime,
      permissionMargin: permissionMargin,
      autoCreatePermission: autoPermission,
    ),
    serviceId: args['relay-service-id'] as String,
    publish: publish,
    metadata: metadata,
    transportLabel: relayTransport == TurnTransport.tcp ? 'tcp' : 'udp',
    description: description,
  );
}

Duration _parseDurationOption(
  String? raw,
  String optionName, {
  required Duration defaultValue,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return defaultValue;
  }
  final parsed = _tryParseDuration(raw.trim());
  if (parsed == null) {
    throw FormatException(
      'Опция $optionName должна быть числом с суффиксом времени (например, 5s, 2m, 1000ms).',
    );
  }
  return parsed;
}

Duration? _parseOptionalDuration(String? raw, String optionName) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  final parsed = _tryParseDuration(raw.trim());
  if (parsed == null) {
    throw FormatException(
      'Опция $optionName должна быть числом с суффиксом времени (например, 5s, 2m, 1000ms).',
    );
  }
  if (parsed.isNegative) {
    throw FormatException('Опция $optionName должна быть положительной.');
  }
  return parsed;
}

Duration? _tryParseDuration(String raw) {
  final normalized = raw.toLowerCase();
  String numberPart;
  Duration Function(int value) builder;

  if (normalized.endsWith('ms')) {
    numberPart = normalized.substring(0, normalized.length - 2);
    builder = (value) => Duration(milliseconds: value);
  } else if (normalized.endsWith('s')) {
    numberPart = normalized.substring(0, normalized.length - 1);
    builder = (value) => Duration(seconds: value);
  } else if (normalized.endsWith('m')) {
    numberPart = normalized.substring(0, normalized.length - 1);
    builder = (value) => Duration(minutes: value);
  } else if (normalized.endsWith('h')) {
    numberPart = normalized.substring(0, normalized.length - 1);
    builder = (value) => Duration(hours: value);
  } else {
    numberPart = normalized;
    builder = (value) => Duration(milliseconds: value);
  }

  if (numberPart.isEmpty) {
    return null;
  }
  final value = int.tryParse(numberPart);
  if (value == null) {
    return null;
  }
  return builder(value);
}

int _parseIntOption(
  String? raw,
  String optionName, {
  int? minValue,
  int? maxValue,
}) {
  final value = _parseOptionalInt(
    raw,
    optionName: optionName,
    minValue: minValue,
    maxValue: maxValue,
  );
  if (value == null) {
    throw FormatException('Опция $optionName обязательна.');
  }
  return value;
}

int? _parseOptionalInt(
  String? raw, {
  required String optionName,
  int? minValue,
  int? maxValue,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) {
    throw FormatException('Опция $optionName должна быть целым числом.');
  }
  if (minValue != null && parsed < minValue) {
    throw FormatException('Опция $optionName должна быть >= $minValue.');
  }
  if (maxValue != null && parsed > maxValue) {
    throw FormatException('Опция $optionName должна быть <= $maxValue.');
  }
  return parsed;
}

Future<InternetAddress> _resolveAddress(String raw, String optionName) async {
  final direct = InternetAddress.tryParse(raw);
  if (direct != null) {
    return direct;
  }
  try {
    final results = await InternetAddress.lookup(raw);
    if (results.isEmpty) {
      throw FormatException('Не удалось разрешить адрес $raw для $optionName.');
    }
    return results.first;
  } on SocketException catch (error) {
    throw FormatException(
      'Не удалось разрешить адрес $raw для $optionName: ${error.message}',
    );
  }
}

Map<String, String> _parseKeyValueMetadata(
  List<String> entries,
  String optionName,
) {
  final metadata = <String, String>{};
  for (final entry in entries) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final separator = trimmed.indexOf('=');
    if (separator <= 0 || separator == trimmed.length - 1) {
      throw FormatException(
        'Опция $optionName принимает значения в формате ключ=значение. Получено: "$entry".',
      );
    }
    final key = trimmed.substring(0, separator).trim();
    final value = trimmed.substring(separator + 1).trim();
    if (key.isEmpty) {
      throw FormatException(
        'Опция $optionName содержит пустой ключ в "$entry".',
      );
    }
    metadata[key] = value;
  }
  return metadata;
}

String _composeRelayDescription(
  String? description,
  Map<String, String> metadata,
) {
  if (metadata.isEmpty) {
    return description ?? '';
  }
  final encodedMetadata = jsonEncode(metadata);
  if (description == null || description.isEmpty) {
    return encodedMetadata;
  }
  return '$description\n$encodedMetadata';
}
