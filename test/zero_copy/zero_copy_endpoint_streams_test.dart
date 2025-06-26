// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  @override
  Map<String, dynamic> toJson() => {'message': message};

  static TestRequest fromJson(Map<String, dynamic> json) =>
      TestRequest(json['message']);

  @override
  String toString() => 'TestRequest($message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TestRequest && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

class TestResponse implements IRpcSerializable {
  final String result;

  TestResponse(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  static TestResponse fromJson(Map<String, dynamic> json) =>
      TestResponse(json['result']);

  @override
  String toString() => 'TestResponse($result)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TestResponse && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class ZeroCopyTestService extends RpcResponderContract {
  ZeroCopyTestService() : super('ZeroCopyTestService');

  @override
  void setup() {
    // Server Stream Method - TRUE ZERO-COPY (без кодеков)
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'GetNumbers',
      handler: (request, {context}) async* {
        print('🔥 SERVER HANDLER получил: ${request.message}');
        final count = int.tryParse(request.message) ?? 3;
        for (int i = 1; i <= count; i++) {
          yield TestResponse('Number $i for: ${request.message}');
          await Future.delayed(Duration(milliseconds: 1));
        }
        print('🔥 SERVER HANDLER завершен');
      },
      // НЕ указываем кодеки → автоматически zero-copy режим!
    );

    // Client Stream Method - TRUE ZERO-COPY (без кодеков)
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ProcessItems',
      handler: (requests, {context}) async {
        print('🔥 CLIENT HANDLER запущен');
        final items = <String>[];
        await for (final request in requests) {
          print('🔥 CLIENT HANDLER получил: ${request.message}');
          items.add(request.message);
        }
        final response = TestResponse(
            'Processed ${items.length} items: ${items.join(", ")}');
        print('🔥 CLIENT HANDLER завершен: ${response.result}');
        return response;
      },
      // НЕ указываем кодеки → автоматически zero-copy режим!
    );

    // Bidirectional Stream Method - TRUE ZERO-COPY (без кодеков)
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'Chat',
      handler: (requests, {context}) async* {
        print('🔥 BIDIRECTIONAL HANDLER запущен');
        await for (final request in requests) {
          print('🔥 BIDIRECTIONAL HANDLER получил: ${request.message}');
          if (request.message.startsWith('ping')) {
            yield TestResponse('pong');
          } else {
            yield TestResponse('echo: ${request.message}');
          }
          await Future.delayed(Duration(milliseconds: 1));
        }
        print('🔥 BIDIRECTIONAL HANDLER завершен');
      },
      // НЕ указываем кодеки → автоматически zero-copy режим!
    );
  }
}

void main() {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);

  group('Zero-Copy Endpoint Streams Tests', () {
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late ZeroCopyTestService testService;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

    setUp(() async {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
      testService = ZeroCopyTestService();
      serverEndpoint.registerServiceContract(testService);
      serverEndpoint.start();

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    test('Server Stream через Endpoint с Zero-Copy', () async {
      print('\n=== SERVER STREAM ЧЕРЕЗ ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('🚀 Zero-copy запрос: ${message.directPayload}');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        if (message.isDirect) {
          print('🚀 Zero-copy ответ: ${message.directPayload}');
        }
      });

      final request = TestRequest('3');
      final responses = <TestResponse>[];

      print('📤 Вызываем serverStream через endpoint...');

      try {
        await for (final response in clientEndpoint
            .serverStream<TestRequest, TestResponse>(
              serviceName: 'ZeroCopyTestService',
              methodName: 'GetNumbers',
              request: request,
            )
            .timeout(Duration(seconds: 5))) {
          responses.add(response);
          print('📥 Получен ответ: ${response.result}');
        }
      } catch (e) {
        print('❌ Ошибка: $e');
      }

      await Future.delayed(Duration(milliseconds: 1));

      print('\n📊 Анализ:');
      print('   Ответов получено: ${responses.length}');
      print('   Всего сообщений: ${sentMessages.length}');

      final directCount = sentMessages.where((m) => m.isDirect).length;
      final serializedCount = sentMessages.where((m) => m.isSerialized).length;

      print('   🚀 Zero-copy: $directCount');
      print('   📡 Сериализованных: $serializedCount');

      expect(responses.length, equals(3));
      expect(directCount, greaterThan(0),
          reason: 'Ожидаем zero-copy сообщения');

      if (directCount > serializedCount) {
        print('\n✅ ОТЛИЧНО! Zero-copy работает через endpoint!');
      }
    });

    test('Client Stream через Endpoint с Zero-Copy', () async {
      print('\n=== CLIENT STREAM ЧЕРЕЗ ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('🚀 Zero-copy запрос: ${message.directPayload}');
        }
      });

      final requests = [
        TestRequest('item1'),
        TestRequest('item2'),
        TestRequest('item3'),
      ];

      print('📤 Вызываем clientStream через endpoint...');

      try {
        final response = await clientEndpoint
            .clientStream<TestRequest, TestResponse>(
              serviceName: 'ZeroCopyTestService',
              methodName: 'ProcessItems',
            )(Stream.fromIterable(requests))
            .timeout(Duration(seconds: 5));

        print('📥 Получен ответ: ${response.result}');

        await Future.delayed(Duration(milliseconds: 1));

        print('\n📊 Анализ:');
        final directCount = sentMessages.where((m) => m.isDirect).length;
        final serializedCount =
            sentMessages.where((m) => m.isSerialized).length;

        print('   🚀 Zero-copy: $directCount');
        print('   📡 Сериализованных: $serializedCount');

        expect(response.result, contains('Processed 3 items'));
        expect(directCount, greaterThan(0),
            reason: 'Ожидаем zero-copy сообщения');

        if (directCount > serializedCount) {
          print('\n✅ ОТЛИЧНО! Client Stream Zero-copy работает!');
        }
      } catch (e) {
        print('❌ Ошибка: $e');
        fail('Client stream failed: $e');
      }
    });

    test('Bidirectional Stream через Endpoint с Zero-Copy', () async {
      print('\n=== BIDIRECTIONAL STREAM ЧЕРЕЗ ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('🚀 Zero-copy запрос: ${message.directPayload}');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        if (message.isDirect) {
          print('🚀 Zero-copy ответ: ${message.directPayload}');
        }
      });

      final requestController = StreamController<TestRequest>();
      final responses = <TestResponse>[];

      print('📤 Вызываем bidirectionalStream через endpoint...');

      try {
        final responseStream =
            clientEndpoint.bidirectionalStream<TestRequest, TestResponse>(
          serviceName: 'ZeroCopyTestService',
          methodName: 'Chat',
          requests: requestController.stream,
        );

        final subscription = responseStream.listen((response) {
          responses.add(response);
          print('📥 Получен ответ: ${response.result}');
        });

        // Отправляем запросы
        requestController.add(TestRequest('ping 1'));
        await Future.delayed(Duration(milliseconds: 1));

        requestController.add(TestRequest('hello'));
        await Future.delayed(Duration(milliseconds: 1));

        await requestController.close();
        await Future.delayed(Duration(milliseconds: 1));

        print('\n📊 Анализ:');
        final directCount = sentMessages.where((m) => m.isDirect).length;
        final serializedCount =
            sentMessages.where((m) => m.isSerialized).length;

        print('   Ответов получено: ${responses.length}');
        print('   🚀 Zero-copy: $directCount');
        print('   📡 Сериализованных: $serializedCount');

        expect(responses.length, greaterThanOrEqualTo(2));
        expect(directCount, greaterThan(0),
            reason: 'Ожидаем zero-copy сообщения');

        if (directCount > serializedCount) {
          print('\n✅ ОТЛИЧНО! Bidirectional Stream Zero-copy работает!');
        }

        await subscription.cancel();
      } catch (e) {
        print('❌ Ошибка: $e');
        fail('Bidirectional stream failed: $e');
      }
    });
  });
}
