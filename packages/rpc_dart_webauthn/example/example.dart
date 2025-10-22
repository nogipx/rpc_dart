// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';

/// Пример использования WebAuthn домена с веб-сервером
///
/// Демонстрирует новый подход с раздельным созданием caller'а и responder'а,
/// а также различные сценарии запуска веб-сервера
/// для отдачи .well-known файлов мобильным аутентификаторам.
void main() async {
  print('🚀 === WEBAUTHN НОВАЯ АРХИТЕКТУРА === 🚀\n');

  // 1. 🎯 Новый подход: раздельное создание caller'а и responder'а
  await _exampleSeparateCallerResponder();

  // 2. Embedded домен с веб-сервером для разработки
  await _exampleDevelopmentWithServer();

  // 3. Продакшен конфигурация с веб-сервером
  await _exampleProductionServer();

  print('\n🎉 === ВСЕ ПРИМЕРЫ ЗАВЕРШЕНЫ === 🎉');
}

/// 1. 🎯 Новый подход: Создание caller'а и responder'а раздельно
Future<void> _exampleSeparateCallerResponder() async {
  print('📱 1. WebAuthn домен с раздельным созданием (новая архитектура)');

  final config = WebAuthnDomainConfig.inMemory(
    rpId: 'localhost',
    rpName: 'WebAuthn Demo',
    webOrigin: 'http://localhost:8080',
    androidPackageName: 'com.example.webauthn',
    // startWellKnownServer: false - по умолчанию
  );

  // === 🎯 Создаем транспорты сами (не в WebAuthn библиотеке) ===
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // === 🎯 Создаем caller и responder через отдельные фабрики ===
  final callerResult = WebAuthnCallerFactory.create(transport: clientTransport);
  final responderResult = await WebAuthnResponderFactory.create(
    config: config,
    transport: serverTransport,
  );

  print('   ✅ WebAuthn caller создан');
  print('   ✅ WebAuthn responder создан');
  print('   ℹ️  Веб-сервер НЕ запущен');
  print('   ⚠️  .well-known файлы недоступны');

  // Демонстрируем использование
  try {
    await callerResult.webAuthnCaller.startRegistration(
      StartRegistrationParams(userId: 'user123'),
    );
    print('   ✅ Тест регистрации прошел успешно');
  } catch (e) {
    print('   ❌ Ошибка тестирования: $e');
  }

  await responderResult.dispose();
  print('   🧹 Домен остановлен\n');
}

/// 2. Embedded домен с веб-сервером для разработки
Future<void> _exampleDevelopmentWithServer() async {
  print('🛠️  2. WebAuthn домен + веб-сервер для разработки');

  final config = WebAuthnDomainConfig.inMemory(
    rpId: 'localhost',
    rpName: 'WebAuthn Demo',
    webOrigin: 'http://localhost:8080',
    androidPackageName: 'com.example.webauthn',
    androidSha256:
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00',
    iosBundleId: 'TEAMID.com.example.webauthn',

    // 🎯 Включаем веб-сервер для разработки
    startWellKnownServer: true,
    serverConfig: WebAuthnServerConfig.development(
      host: 'localhost',
      port: 8081, // Отдельный порт для .well-known
    ),
  );

  // === 🎯 Используем новую архитектуру ===
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  WebAuthnCallerFactory.create(transport: clientTransport);
  final responderResult = await WebAuthnResponderFactory.create(
    config: config,
    transport: serverTransport,
  );

  print('   ✅ WebAuthn домен создан');
  if (responderResult.wellKnownServer?.isRunning == true) {
    final port = responderResult.wellKnownServer!.actualPort;
    print('   🌐 Веб-сервер запущен на http://localhost:$port');

    // Демонстрируем работу сервера
    await _testWellKnownEndpoints('localhost', port!);
  } else {
    print('   ❌ Веб-сервер не запустился');
  }

  await responderResult.dispose();
  print('   🧹 Домен и веб-сервер остановлены\n');
}

/// 3. Продакшен конфигурация с веб-сервером
Future<void> _exampleProductionServer() async {
  print('🏭 3. Продакшен конфигурация с веб-сервером');

  // Генерируем продакшен секретный ключ
  final secretKey = List.generate(32, (i) => (i * 7 + 13) % 256);

  try {
    final config = WebAuthnDomainConfig.production(
      rpId: 'mycompany.com',
      rpName: 'My Company App',
      webOrigin: Uri.parse('https://mycompany.com'),
      androidAppInfo: ProductConfigAndroid(
        packageName: 'com.mycompany.app',
        sha256:
            'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
      ),
      iosBundleId: 'TEAM123.com.mycompany.app',
      secretKey: secretKey,

      // 🎯 Включаем веб-сервер для продакшена
      startWellKnownServer: true,
      serverConfig: WebAuthnServerConfig.production(
        host: '0.0.0.0',
        port: 8082, // В продакшене обычно 443 (HTTPS)
        additionalHeaders: {
          'Server': 'WebAuthn-Server/1.0',
          'X-Company': 'MyCompany',
        },
      ),
    );

    // === 🎯 Используем новую архитектуру ===
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    WebAuthnCallerFactory.create(transport: clientTransport);
    final responderResult = await WebAuthnResponderFactory.create(
      config: config,
      transport: serverTransport,
    );

    print('   ✅ Продакшен домен создан');
    if (responderResult.wellKnownServer?.isRunning == true) {
      final port = responderResult.wellKnownServer!.actualPort;
      print('   🌐 Продакшен веб-сервер запущен на http://0.0.0.0:$port');
      print('   🔒 Настроены заголовки безопасности');

      // Демонстрируем работу продакшен сервера
      await _testWellKnownEndpoints('localhost', port!);
    } else {
      print('   ❌ Продакшен веб-сервер не запустился');
    }

    await responderResult.dispose();
    print('   🧹 Продакшен домен и веб-сервер остановлены\n');
  } catch (e) {
    print('   ❌ Ошибка создания продакшен конфигурации: $e\n');
  }
}

/// Тестирует .well-known endpoints
Future<void> _testWellKnownEndpoints(String host, int port) async {
  print('   🧪 Тестируем .well-known endpoints:');

  try {
    final client = HttpClient();

    // Тест корневого пути
    final rootRequest = await client.get(host, port, '/');
    final rootResponse = await rootRequest.close();
    if (rootResponse.statusCode == 200) {
      print('      ✅ GET / - OK');
    }

    // Тест Android assetlinks.json
    final androidRequest = await client.get(host, port, '/.well-known/assetlinks.json');
    final androidResponse = await androidRequest.close();
    if (androidResponse.statusCode == 200) {
      print('      ✅ GET /.well-known/assetlinks.json - OK');
    }

    // Тест iOS apple-app-site-association
    final iosRequest = await client.get(host, port, '/.well-known/apple-app-site-association');
    final iosResponse = await iosRequest.close();
    if (iosResponse.statusCode == 200) {
      print('      ✅ GET /.well-known/apple-app-site-association - OK');
    }

    // Тест 404
    final notFoundRequest = await client.get(host, port, '/nonexistent');
    final notFoundResponse = await notFoundRequest.close();
    if (notFoundResponse.statusCode == 404) {
      print('      ✅ GET /nonexistent - 404 (как ожидалось)');
    }

    client.close();
  } catch (e) {
    print('      ❌ Ошибка тестирования endpoints: $e');
  }
}
