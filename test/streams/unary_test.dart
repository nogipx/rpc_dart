import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Создает транспортную пару для тестирования
(IRpcTransport, IRpcTransport) createTransportPair() =>
    RpcInMemoryTransport.pair();

void main() {
  group('Unary RPC', () {
    final serializer = RpcCodec(RpcString.fromJson);

    group('UnaryClient', () {
      test('отправляет_запрос_и_получает_ответ', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();
        final receivedRequests = <RpcString>[];

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            receivedRequests.add(request);
            return 'Echo: $request'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: RpcLogger('TestUnaryClient'),
        );

        // Act
        final response = await client.call('test request'.rpc);

        // Assert
        expect(response, equals('Echo: test request'.rpc));
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('test request'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('выбрасывает_исключение_при_ошибке_сервера', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            throw Exception('Internal server error');
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: RpcLogger('TestUnaryClient'),
        );

        // Act & Assert
        await expectLater(
          client.call('test request'.rpc),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('gRPC error'),
          )),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('применяет_таймаут_к_запросу', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async {
            // Задержка больше таймаута
            await Future.delayed(Duration(seconds: 1));
            return 'Delayed response'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: RpcLogger('TestUnaryClient'),
        );

        // Act & Assert
        expect(
          () => client.call(
            'test request'.rpc,
            timeout: Duration(milliseconds: 100),
          ),
          throwsA(isA<TimeoutException>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (clientTransport, _) = createTransportPair();

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: RpcLogger('TestUnaryClient'),
        );

        // Act & Assert
        await client.close();
        expect(true, isTrue); // No exceptions
      });

      test('создает_уникальные_stream_id_для_каждого_вызова', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();
        final receivedStreamIds = <int>[];

        // Отслеживаем входящие stream IDs
        serverTransport.incomingMessages.listen((message) {
          if (message.isMetadataOnly) {
            receivedStreamIds.add(message.streamId);
          }
        });

        // Создаем простой сервер
        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) => 'Echo: $request'.rpc,
        );

        // Act - делаем несколько вызовов
        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Делаем три последовательных вызова
        await client.call('request 1'.rpc);
        await client.call('request 2'.rpc);
        await client.call('request 3'.rpc);

        // Assert
        expect(receivedStreamIds.length, equals(3));
        expect(receivedStreamIds.toSet().length, equals(3)); // Все уникальные

        // Cleanup
        await client.close();
        await server.close();
      });
    });

    group('UnaryServer', () {
      test('обрабатывает_запрос_и_отправляет_ответ', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final receivedRequests = <RpcString>[];

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            receivedRequests.add(request);
            return 'Echo: $request'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response = await client.call('Hello Server'.rpc);

        // Assert
        expect(response, equals('Echo: Hello Server'.rpc));
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('Hello Server'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('отправляет_ошибку_при_исключении_в_обработчике', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            throw Exception('Handler error');
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await expectLater(
          client.call('test request'.rpc),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('gRPC error'),
          )),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_только_запросы_своего_метода', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        var handlerCallCount = 0;
        final receivedRequests = <RpcString>[];

        // Сервер для конкретного метода
        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            handlerCallCount++;
            receivedRequests.add(request);
            return 'response from SpecificMethod'.rpc;
          },
        );

        // Второй сервер для другого метода
        final otherServer = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            return 'response from DifferentMethod'.rpc;
          },
        );

        // Создаем клиентов для разных методов
        final correctClient = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final otherClient = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response1 = await correctClient.call('correct request'.rpc);
        final response2 = await otherClient.call('other request'.rpc);

        // Assert
        expect(handlerCallCount,
            equals(1)); // Только один вызов конкретного обработчика
        expect(receivedRequests, equals(['correct request'.rpc]));
        expect(response1, equals('response from SpecificMethod'.rpc));
        expect(response2, equals('response from DifferentMethod'.rpc));

        // Cleanup
        await correctClient.close();
        await otherClient.close();
        await server.close();
        await otherServer.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (_, serverTransport) = createTransportPair();

        final sut = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) => 'response'.rpc,
        );

        // Act
        await sut.close();

        // Assert
        // Проверяем, что нет исключений при закрытии
        expect(true, isTrue);
      });
    });

    group('интеграционные тесты', () {
      test('полный_цикл_запрос_ответ_работает_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'EchoService',
          methodName: 'Echo',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) => 'Echo: $request'.rpc,
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'EchoService',
          methodName: 'Echo',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response1 = await client.call('Hello'.rpc);
        final response2 = await client.call('World'.rpc);

        // Assert
        expect(response1, equals('Echo: Hello'.rpc));
        expect(response2, equals('Echo: World'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('несколько_клиентов_могут_использовать_один_сервер', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        var requestCount = 0;

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'CounterService',
          methodName: 'Increment',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            requestCount++;
            return 'Count: $requestCount'.rpc;
          },
        );

        // Act - создаем несколько клиентов
        final responses = <RpcString>[];
        for (int i = 0; i < 3; i++) {
          final client = UnaryCaller<RpcString, RpcString>(
            transport: clientTransport,
            serviceName: 'CounterService',
            methodName: 'Increment',
            requestCodec: serializer,
            responseCodec: serializer,
          );

          responses.add(await client.call('increment'.rpc));
          await client.close();
        }

        // Assert
        expect(responses.length, equals(3));
        expect(responses[0], equals('Count: 1'.rpc));
        expect(responses[1], equals('Count: 2'.rpc));
        expect(responses[2], equals('Count: 3'.rpc));

        // Cleanup
        await server.close();
      });
    });
  });
}
