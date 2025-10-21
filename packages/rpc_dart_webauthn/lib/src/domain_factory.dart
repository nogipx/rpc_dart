import 'dart:io';
import 'package:collection/collection.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'data/_index.dart';
import 'domain/_index.dart';
import 'rpc/_index.dart';
import 'usecases/_index.dart';
import 'utils/_index.dart';

/// Конфигурация веб-сервера для отдачи .well-known файлов
class WebAuthnServerConfig {
  /// Хост для привязки сервера
  final String host;

  /// Порт для привязки сервера
  final int port;

  /// Включать ли CORS заголовки
  final bool enableCors;

  /// Дополнительные заголовки для ответов
  final Map<String, String> additionalHeaders;

  /// Логировать ли запросы
  final bool logRequests;

  const WebAuthnServerConfig({
    this.host = '0.0.0.0',
    this.port = 8080,
    this.enableCors = true,
    this.additionalHeaders = const {},
    this.logRequests = true,
  });

  /// Конфигурация для разработки
  factory WebAuthnServerConfig.development({
    String host = 'localhost',
    int port = 8080,
  }) {
    return WebAuthnServerConfig(
      host: host,
      port: port,
      enableCors: true,
      logRequests: true,
      additionalHeaders: {
        'X-Environment': 'development',
      },
    );
  }

  /// Конфигурация для продакшена
  factory WebAuthnServerConfig.production({
    String host = '0.0.0.0',
    int port = 443,
    Map<String, String> additionalHeaders = const {},
  }) {
    return WebAuthnServerConfig(
      host: host,
      port: port,
      enableCors: false,
      logRequests: false,
      additionalHeaders: {
        'X-Environment': 'production',
        'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        ...additionalHeaders,
      },
    );
  }
}

/// Конфигурация для WebAuthn домена
class WebAuthnDomainConfig {
  /// ID полагающейся стороны (обычно домен)
  final String rpId;

  /// Имя полагающейся стороны
  final String rpName;

  /// Настройки веб-происхождения
  final Uri webOrigin;

  /// Информация о Android приложении
  final ProductConfigAndroid? androidAppInfo;

  /// Bundle ID для iOS
  final String? iosBundleId;

  /// Требовать ли верификацию пользователя
  final bool requireUserVerification;

  /// Таймаут challenge в секундах
  final int challengeTimeout;

  /// Время жизни токена в секундах
  final int tokenLifetime;

  /// Области доступа для токена
  final List<String> scopes;

  /// Секретный ключ для PASETO токенов (32 байта)
  final List<int>? secretKey;

  /// Конфигурация веб-сервера (опционально)
  final WebAuthnServerConfig? serverConfig;

  const WebAuthnDomainConfig({
    required this.rpId,
    required this.rpName,
    required this.webOrigin,
    this.androidAppInfo,
    this.iosBundleId,
    this.requireUserVerification = false,
    this.challengeTimeout = 300, // 5 минут
    this.tokenLifetime = 3600, // 1 час
    this.scopes = const ['user', 'webauthn.authenticated'],
    this.secretKey,
    this.serverConfig,
  });

  /// Конфигурация для InMemory транспорта (разработка)
  factory WebAuthnDomainConfig.inMemory({
    String rpId = 'localhost',
    String rpName = 'WebAuthn Demo',
    String webOrigin = 'http://localhost:8080',
    String? androidPackageName,
    String? androidSha256,
    String? iosBundleId,
    bool requireUserVerification = false,
    int challengeTimeout = 300,
    int tokenLifetime = 3600,
    List<String> scopes = const ['user', 'webauthn.authenticated'],

    // Новые параметры для веб-сервера
    bool startWellKnownServer = false,
    WebAuthnServerConfig? serverConfig,
  }) {
    return WebAuthnDomainConfig(
      rpId: rpId,
      rpName: rpName,
      webOrigin: Uri.parse(webOrigin),
      androidAppInfo: androidPackageName != null
          ? ProductConfigAndroid(
              packageName: androidPackageName,
              sha256: androidSha256 ?? _generateDevelopmentSha256(),
            )
          : null,
      iosBundleId: iosBundleId,
      requireUserVerification: requireUserVerification,
      challengeTimeout: challengeTimeout,
      tokenLifetime: tokenLifetime,
      scopes: scopes,
      serverConfig:
          startWellKnownServer ? (serverConfig ?? WebAuthnServerConfig.development()) : null,
    );
  }

  /// Конфигурация для продакшена с валидацией безопасности
  factory WebAuthnDomainConfig.production({
    required String rpId,
    required String rpName,
    required Uri webOrigin,
    required ProductConfigAndroid androidAppInfo,
    required String iosBundleId,
    required List<int> secretKey,
    bool requireUserVerification = true,
    int challengeTimeout = 300,
    int tokenLifetime = 3600,
    List<String> scopes = const ['user', 'webauthn.authenticated'],

    // Новые параметры для веб-сервера
    bool startWellKnownServer = true,
    WebAuthnServerConfig? serverConfig,
  }) {
    if (secretKey.length != 32) {
      throw ArgumentError('Secret key must be exactly 32 bytes');
    }

    // Проверяем, что не используются тестовые данные
    _validateProductionData(
      rpId: rpId,
      rpName: rpName,
      webOrigin: webOrigin,
      androidAppInfo: androidAppInfo,
      iosBundleId: iosBundleId,
      secretKey: secretKey,
    );

    return WebAuthnDomainConfig(
      rpId: rpId,
      rpName: rpName,
      webOrigin: webOrigin,
      androidAppInfo: androidAppInfo,
      iosBundleId: iosBundleId,
      requireUserVerification: requireUserVerification,
      challengeTimeout: challengeTimeout,
      tokenLifetime: tokenLifetime,
      scopes: scopes,
      secretKey: secretKey,
      serverConfig:
          startWellKnownServer ? (serverConfig ?? WebAuthnServerConfig.production()) : null,
    );
  }

  /// Валидация продакшен данных
  static void _validateProductionData({
    required String rpId,
    required String rpName,
    required Uri webOrigin,
    required ProductConfigAndroid androidAppInfo,
    required String iosBundleId,
    required List<int> secretKey,
  }) {
    final errors = <String>[];

    // Проверяем тестовые значения
    if (rpId == 'localhost' || rpId.contains('test') || rpId.contains('dev')) {
      errors.add('Production rpId cannot be localhost, test, or dev: $rpId');
    }

    if (rpName.toLowerCase().contains('demo') ||
        rpName.toLowerCase().contains('test') ||
        rpName.toLowerCase().contains('dev')) {
      errors.add('Production rpName cannot contain demo, test, or dev: $rpName');
    }

    if (webOrigin.host == 'localhost' ||
        webOrigin.host.contains('test') ||
        webOrigin.host.contains('dev')) {
      errors.add('Production webOrigin cannot be localhost, test, or dev: ${webOrigin.host}');
    }

    if (androidAppInfo.packageName.contains('example') ||
        androidAppInfo.packageName.contains('test') ||
        androidAppInfo.packageName.contains('dev')) {
      errors.add(
          'Production Android package cannot contain example, test, or dev: ${androidAppInfo.packageName}');
    }

    if (androidAppInfo.sha256 == _generateDevelopmentSha256()) {
      errors.add('Production Android SHA256 cannot be the development default');
    }

    if (iosBundleId.contains('example') ||
        iosBundleId.contains('test') ||
        iosBundleId.contains('dev')) {
      errors.add('Production iOS bundle ID cannot contain example, test, or dev: $iosBundleId');
    }

    // Проверяем тестовый ключ
    final testKey = List.generate(32, (index) => index + 1);
    if (const ListEquality().equals(secretKey, testKey)) {
      errors.add('Production secret key cannot be the development default');
    }

    if (errors.isNotEmpty) {
      throw ArgumentError('Production validation failed:\n${errors.join('\n')}');
    }
  }

  static String _generateDevelopmentSha256() {
    return '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00';
  }
}

/// Веб-сервер для отдачи .well-known файлов
class WebAuthnWellKnownServer {
  final WebAuthnServerConfig config;
  final ProductConfig productConfig;
  HttpServer? _server;
  bool _isRunning = false;

  WebAuthnWellKnownServer({
    required this.config,
    required this.productConfig,
  });

  /// Запускает веб-сервер
  Future<void> start() async {
    if (_isRunning) {
      throw StateError('Сервер уже запущен');
    }

    try {
      _server = await HttpServer.bind(config.host, config.port);
      _isRunning = true;

      if (config.logRequests) {
        print('🌐 WebAuthn .well-known сервер запущен на http://${config.host}:${config.port}');
        print('   • Android: /.well-known/assetlinks.json');
        print('   • iOS: /.well-known/apple-app-site-association');
      }

      // Обрабатываем входящие запросы
      _server!.listen(_handleRequest);
    } catch (e) {
      _isRunning = false;
      rethrow;
    }
  }

  /// Останавливает веб-сервер
  Future<void> stop() async {
    if (!_isRunning || _server == null) return;

    await _server!.close();
    _server = null;
    _isRunning = false;

    if (config.logRequests) {
      print('🛑 WebAuthn .well-known сервер остановлен');
    }
  }

  /// Обрабатывает HTTP запрос
  void _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      if (config.logRequests) {
        print('📥 ${request.method} $path от ${request.connectionInfo?.remoteAddress}');
      }

      // Устанавливаем базовые заголовки
      _setHeaders(request.response);

      // Обрабатываем запросы к .well-known
      if (path == '/.well-known/assetlinks.json') {
        await _handleAndroidAssetLinks(request);
      } else if (path == '/.well-known/apple-app-site-association') {
        await _handleAppleAppSiteAssociation(request);
      } else if (path == '/') {
        await _handleRootPath(request);
      } else {
        // 404 для всех остальных путей
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('{"error": "Not Found"}');
      }
    } catch (e) {
      print('❌ Ошибка обработки запроса: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('{"error": "Internal Server Error"}');
    } finally {
      await request.response.close();
    }
  }

  /// Устанавливает HTTP заголовки
  void _setHeaders(HttpResponse response) {
    response.headers.contentType = ContentType.json;

    // Базовые заголовки безопасности
    if (config.enableCors) {
      response.headers.set('Access-Control-Allow-Origin', '*');
      response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
      response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    }

    // Дополнительные заголовки
    config.additionalHeaders.forEach((key, value) {
      response.headers.set(key, value);
    });

    // Заголовки кэширования для .well-known файлов
    response.headers.set('Cache-Control', 'public, max-age=3600'); // Кэш на 1 час
  }

  /// Обрабатывает запрос к Android assetlinks.json
  Future<void> _handleAndroidAssetLinks(HttpRequest request) async {
    final json = productConfig.getAndroidAssetLinksJson();
    request.response.write(json);

    if (config.logRequests) {
      print('✅ Отдан Android assetlinks.json');
    }
  }

  /// Обрабатывает запрос к iOS apple-app-site-association
  Future<void> _handleAppleAppSiteAssociation(HttpRequest request) async {
    final json = productConfig.getAppleAppSiteAssociationJson();
    request.response.write(json);

    if (config.logRequests) {
      print('✅ Отдан iOS apple-app-site-association');
    }
  }

  /// Обрабатывает запрос к корневому пути
  Future<void> _handleRootPath(HttpRequest request) async {
    final info = {
      'service': 'WebAuthn Well-Known Server',
      'status': 'running',
      'endpoints': [
        '/.well-known/assetlinks.json',
        '/.well-known/apple-app-site-association',
      ],
      'rpId': productConfig.webOrigin.host,
      'environment': config.additionalHeaders['X-Environment'] ?? 'unknown',
    };

    request.response.write(info);
  }

  /// Проверяет, запущен ли сервер
  bool get isRunning => _isRunning;

  /// Получает фактический порт сервера
  int? get actualPort => _server?.port;
}

/// Результат создания WebAuthn caller'а (клиентской части)
class WebAuthnCallerResult {
  /// WebAuthn caller для типизированных вызовов
  final WebAuthnCaller webAuthnCaller;

  /// Клиентский endpoint для прямого доступа
  final RpcCallerEndpoint clientEndpoint;

  const WebAuthnCallerResult({
    required this.webAuthnCaller,
    required this.clientEndpoint,
  });
}

/// Результат создания WebAuthn responder'а (серверной части)
class WebAuthnResponderResult {
  /// Серверный endpoint с зарегистрированным responder'ом
  final RpcResponderEndpoint serverEndpoint;

  /// WebAuthn responder для прямого доступа
  final WebAuthnResponder webAuthnResponder;

  /// Репозитории (для прямого доступа при необходимости)
  final IWebAuthnRepository webAuthnRepository;
  final ISessionRepository sessionRepository;
  final IChallengeRepository challengeRepository;
  final ITokenBlacklistRepository tokenBlacklistRepository;

  /// Веб-сервер для .well-known файлов (опционально)
  final WebAuthnWellKnownServer? wellKnownServer;

  const WebAuthnResponderResult({
    required this.serverEndpoint,
    required this.webAuthnResponder,
    required this.webAuthnRepository,
    required this.sessionRepository,
    required this.challengeRepository,
    required this.tokenBlacklistRepository,
    this.wellKnownServer,
  });

  /// Освобождает ресурсы responder'а
  Future<void> dispose() async {
    serverEndpoint.stop();
    await wellKnownServer?.stop();
  }
}

/// Результат создания полного WebAuthn домена
class WebAuthnDomainResult {
  /// Клиентская часть
  final WebAuthnCallerResult callerResult;

  /// Серверная часть
  final WebAuthnResponderResult responderResult;

  const WebAuthnDomainResult({
    required this.callerResult,
    required this.responderResult,
  });

  // Удобные геттеры для обратной совместимости
  RpcCallerEndpoint get clientEndpoint => callerResult.clientEndpoint;
  RpcResponderEndpoint get serverEndpoint => responderResult.serverEndpoint;
  WebAuthnCaller get webAuthnCaller => callerResult.webAuthnCaller;
  IWebAuthnRepository get webAuthnRepository => responderResult.webAuthnRepository;
  ISessionRepository get sessionRepository => responderResult.sessionRepository;
  IChallengeRepository get challengeRepository => responderResult.challengeRepository;
  ITokenBlacklistRepository get tokenBlacklistRepository =>
      responderResult.tokenBlacklistRepository;
  WebAuthnWellKnownServer? get wellKnownServer => responderResult.wellKnownServer;

  /// Освобождает ресурсы домена
  Future<void> dispose() async {
    await responderResult.dispose();
  }
}

/// 🎯 Фабрика для создания WebAuthn caller'а (клиентская часть)
///
/// Отвечает только за создание клиентской части домена.
/// Минимальные зависимости, максимальная производительность.
class WebAuthnCallerFactory {
  /// Создает WebAuthn caller с внешним транспортом
  ///
  /// Транспорт должен быть предоставлен извне, что позволяет гибко настраивать
  /// коммуникацию (InMemory, HTTP, WebSocket, Isolate и т.д.).
  ///
  /// [transport] - RPC транспорт для коммуникации с сервером
  static WebAuthnCallerResult create({
    required IRpcTransport transport,
  }) {
    final clientEndpoint = RpcCallerEndpoint(transport: transport);
    final webAuthnCaller = WebAuthnCaller(clientEndpoint);

    return WebAuthnCallerResult(
      webAuthnCaller: webAuthnCaller,
      clientEndpoint: clientEndpoint,
    );
  }
}

/// 🎯 Фабрика для создания WebAuthn responder'а (серверная часть)
///
/// Отвечает за создание полной серверной части домена со всеми
/// репозиториями, use cases и бизнес-логикой.
class WebAuthnResponderFactory {
  /// Создает WebAuthn responder с внешним транспортом
  ///
  /// Этот метод создает полную серверную часть WebAuthn домена со всеми
  /// репозиториями, use cases и бизнес-логикой. Транспорт предоставляется
  /// извне для максимальной гибкости.
  ///
  /// [config] - конфигурация домена
  /// [transport] - RPC транспорт для коммуникации с клиентами
  static Future<WebAuthnResponderResult> create({
    required WebAuthnDomainConfig config,
    required IRpcTransport transport,
  }) async {
    // === 1. Создаем репозитории ===
    final webAuthnRepository = MemoryWebAuthnRepositoryImpl();
    final challengeRepository = MemoryChallengeRepositoryImpl();
    final sessionRepository = MemorySessionRepositoryImpl();
    final tokenBlacklistRepository = MemoryTokenBlacklistRepositoryImpl();

    // === 2. Создаем утилиты ===
    final secretKey = config.secretKey ?? _generateDevelopmentSecretKey();
    final pasetoUtils = PasetoUtils(secretKeyBytes: secretKey);

    // === 3. Создаем настройки ===
    final productConfig = ProductConfig(
      webOrigin: config.webOrigin,
      androidAppInfo: config.androidAppInfo ??
          ProductConfigAndroid(
            packageName: 'com.example.dev',
            sha256: WebAuthnDomainConfig._generateDevelopmentSha256(),
          ),
      iosBundleId: config.iosBundleId ?? 'TEAMID.com.example.dev',
    );

    final originConfig = WebAuthnOriginConfig(
      productConfig: productConfig,
      defaultOrigin: config.webOrigin.toString(),
    );

    final settings = WebAuthnSettings(
      rpId: config.rpId,
      rpName: config.rpName,
      originConfig: originConfig,
      requireUserVerification: config.requireUserVerification,
      challengeTimeout: config.challengeTimeout,
      tokenLifetime: config.tokenLifetime,
      scopes: config.scopes,
    );

    // === 4. Создаем use cases ===
    final startRegistrationUseCase = StartRegistrationUseCase(
      challengeRepository,
      rpId: settings.rpId,
      rpName: settings.rpName,
    );

    final finishRegistrationUseCase = FinishRegistrationUseCase(
      webAuthnRepository,
      challengeRepository,
      rpId: settings.rpId,
    );

    final startAuthenticationUseCase = StartAuthenticationUseCase(
      webAuthnRepository,
      challengeRepository,
      settings: settings,
    );

    final finishAuthenticationUseCase = FinishAuthenticationUseCase(
      webAuthnRepository,
      challengeRepository,
      sessionRepository,
      settings: settings,
      pasetoUtils: pasetoUtils,
    );

    final validateTokenUseCase = ValidateTokenUseCase(
      webAuthnRepository,
      sessionRepository,
      tokenBlacklistRepository,
      pasetoUtils,
    );

    final revokeSessionUseCase = RevokeSessionUseCase(
      sessionRepository,
    );

    final authorizationService = WebAuthnAuthorizationService(validateTokenUseCase);

    // === 5. Создаем responder ===
    final webAuthnResponder = WebAuthnResponder(
      startRegistrationUseCase: startRegistrationUseCase,
      finishRegistrationUseCase: finishRegistrationUseCase,
      startAuthenticationUseCase: startAuthenticationUseCase,
      finishAuthenticationUseCase: finishAuthenticationUseCase,
      validateTokenUseCase: validateTokenUseCase,
      revokeSessionUseCase: revokeSessionUseCase,
      webAuthnRepository: webAuthnRepository,
      settings: settings,
      authorizationService: authorizationService,
    );

    // === 6. Создаем серверный endpoint ===
    final serverEndpoint = RpcResponderEndpoint(transport: transport);
    serverEndpoint.registerServiceContract(webAuthnResponder);
    serverEndpoint.start();

    // === 7. Создаем и запускаем веб-сервер для .well-known файлов (если настроен) ===
    WebAuthnWellKnownServer? wellKnownServer;
    if (config.serverConfig != null) {
      wellKnownServer = WebAuthnWellKnownServer(
        config: config.serverConfig!,
        productConfig: productConfig,
      );

      try {
        await wellKnownServer.start();
      } catch (e) {
        print('❌ Ошибка запуска WebAuthn веб-сервера: $e');
        // Не останавливаем создание домена из-за ошибки веб-сервера
        wellKnownServer = null;
      }
    }

    return WebAuthnResponderResult(
      serverEndpoint: serverEndpoint,
      webAuthnResponder: webAuthnResponder,
      webAuthnRepository: webAuthnRepository,
      sessionRepository: sessionRepository,
      challengeRepository: challengeRepository,
      tokenBlacklistRepository: tokenBlacklistRepository,
      wellKnownServer: wellKnownServer,
    );
  }

  /// Генерирует тестовый секретный ключ для разработки
  ///
  /// ⚠️ НЕ ИСПОЛЬЗУЙТЕ В ПРОДАКШЕНЕ! Всегда используйте криптографически стойкие ключи.
  static List<int> _generateDevelopmentSecretKey() {
    return List.generate(32, (index) => index + 1);
  }
}

/// 🔗 Утилитарная фабрика для создания полного WebAuthn домена
///
/// Удобная обертка для одновременного создания caller'а и responder'а.
/// Рекомендуется использовать отдельные фабрики для большего контроля.
class WebAuthnDomainFactory {
  /// Создает полный WebAuthn домен с парными транспортами
  ///
  /// Этот метод создает InMemory транспорты и настраивает
  /// caller и responder для работы в одном процессе.
  ///
  /// **Рекомендуется** использовать [WebAuthnCallerFactory] и [WebAuthnResponderFactory]
  /// для большего контроля над транспортами.
  static Future<WebAuthnDomainResult> createInMemory({
    required WebAuthnDomainConfig config,
  }) async {
    // Создаем InMemory транспорты
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем caller и responder
    final callerResult = WebAuthnCallerFactory.create(transport: clientTransport);
    final responderResult = await WebAuthnResponderFactory.create(
      config: config,
      transport: serverTransport,
    );

    return WebAuthnDomainResult(
      callerResult: callerResult,
      responderResult: responderResult,
    );
  }

  /// Создает WebAuthn домен с внешними транспортами
  ///
  /// [clientTransport] - транспорт для caller'а
  /// [serverTransport] - транспорт для responder'а
  static Future<WebAuthnDomainResult> createWithTransports({
    required WebAuthnDomainConfig config,
    required IRpcTransport clientTransport,
    required IRpcTransport serverTransport,
  }) async {
    final callerResult = WebAuthnCallerFactory.create(transport: clientTransport);
    final responderResult = await WebAuthnResponderFactory.create(
      config: config,
      transport: serverTransport,
    );

    return WebAuthnDomainResult(
      callerResult: callerResult,
      responderResult: responderResult,
    );
  }
}
