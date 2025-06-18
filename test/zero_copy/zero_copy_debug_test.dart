// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// Простые тестовые модели
final class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'message': message};
}

final class TestResponse implements IRpcSerializable {
  final String result;

  TestResponse(this.result);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['result'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'result': result};
}

final class TestService extends RpcResponderContract {
  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'echo',
      handler: (request, {context}) async {
        print('🔥 SERVICE: Получен запрос: ${request.message}');
        final response = TestResponse('Echo: ${request.message}');
        print('🔥 SERVICE: Отправляем ответ: ${response.result}');
        return response;
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('🐛 Zero-Copy Debug', () {
    test('Пошаговый анализ zero-copy', () async {
      print('\n🚀 Настройка inmemory транспорта...');
      final pair = RpcInMemoryTransport.pair();
      final clientTransport = pair.$1;
      final serverTransport = pair.$2;

      print('🚀 Создание endpoint-ов...');
      final responderEndpoint =
          RpcResponderEndpoint(transport: serverTransport);
      final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      print('🚀 Регистрация сервиса...');
      final testService = TestService();
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

      // Логируем ВСЕ сообщения
      serverTransport.incomingMessages.listen((message) {
        print('\n📥 SERVER получил:');
        print('   Stream ID: ${message.streamId}');
        print('   isDirect: ${message.isDirect}');
        print('   isSerialized: ${message.isSerialized}');
        print('   isMetadataOnly: ${message.isMetadataOnly}');
        print('   isEndOfStream: ${message.isEndOfStream}');

        if (message.isDirect) {
          print('   directPayload: ${message.directPayload?.runtimeType}');
        }
        if (message.isSerialized && message.payload != null) {
          print('   payload size: ${message.payload!.length} bytes');
        }
        if (message.metadata != null) {
          print('   metadata headers: ${message.metadata!.headers.length}');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        print('\n📤 CLIENT получил:');
        print('   Stream ID: ${message.streamId}');
        print('   isDirect: ${message.isDirect}');
        print('   isSerialized: ${message.isSerialized}');
        print('   isMetadataOnly: ${message.isMetadataOnly}');
        print('   isEndOfStream: ${message.isEndOfStream}');

        if (message.isDirect) {
          print('   directPayload: ${message.directPayload?.runtimeType}');
        }
        if (message.isSerialized && message.payload != null) {
          print('   payload size: ${message.payload!.length} bytes');
        }
        if (message.metadata != null) {
          print('   metadata headers: ${message.metadata!.headers.length}');
        }
      });

      print('\n🚀 Отправляем RPC запрос...');
      final request = TestRequest('Hello zero-copy!');

      try {
        final response = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'echo',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: request,
        )
            .timeout(Duration(seconds: 5), onTimeout: () {
          print('\n❌ TIMEOUT! Что-то пошло не так...');
          throw TimeoutException('Test timeout', Duration(seconds: 5));
        });

        print('\n✅ УСПЕХ! Получен ответ: ${response.result}');
        expect(response.result, equals('Echo: Hello zero-copy!'));
      } catch (e, stackTrace) {
        print('\n❌ ОШИБКА: $e');
        print('StackTrace: $stackTrace');
        rethrow;
      } finally {
        print('\n🧹 Закрытие endpoint-ов...');
        await responderEndpoint.close();
        await callerEndpoint.close();
      }
    });
  });
}
