// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Полные интеграционные тесты Router'а со всеми типами стриминга
void main() {
  group('🚌🔄 Transport Router Streaming Tests', () {
    // Транспорты для тестирования
    late IRpcTransport userClientTransport, userServerTransport;
    late IRpcTransport paymentClientTransport, paymentServerTransport;
    late IRpcTransport premiumClientTransport, premiumServerTransport;

    setUp(() {
      // Создаем пары транспортов (клиент <-> сервер)
      final userPair = RpcInMemoryTransport.pair();
      userClientTransport = userPair.$1;
      userServerTransport = userPair.$2;

      final paymentPair = RpcInMemoryTransport.pair();
      paymentClientTransport = paymentPair.$1;
      paymentServerTransport = paymentPair.$2;

      final premiumPair = RpcInMemoryTransport.pair();
      premiumClientTransport = premiumPair.$1;
      premiumServerTransport = premiumPair.$2;
    });

    tearDown(() async {
      // Всегда очищаем ресурсы
      await userClientTransport.close();
      await userServerTransport.close();
      await paymentClientTransport.close();
      await paymentServerTransport.close();
      await premiumClientTransport.close();
      await premiumServerTransport.close();
    });

    group('Server Stream через Router', () {
      test('должен корректно роутить server stream по сервису', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
              calledServiceName: 'UserService',
              toTransport: userClientTransport,
              priority: 100,
            )
            .build();

        final serverEndpoint = RpcResponderEndpoint(
          transport: userServerTransport,
        );
        final testService = _TestStreamingService(serviceName: 'UserService');
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final clientEndpoint = RpcCallerEndpoint(transport: router);

        // Act
        final responses = <RpcString>[];
        final responseStream =
            clientEndpoint.serverStream<RpcString, RpcString>(
          serviceName: 'UserService',
          methodName: 'GetNumbers',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: '3'.rpc,
        );

        await for (final response in responseStream) {
          responses.add(response);
        }

        // Assert
        expect(responses.length, equals(3));
        expect(responses[0], equals('Number 1'.rpc));
        expect(testService.callLog, contains('ServerStream: 3'));

        await router.close();
        await serverEndpoint.close();
        await clientEndpoint.close();
      });

      test('должен роутить server stream по приоритету правил', () async {
        // Arrange - роутер с приоритетами
        final router = RpcTransportRouterBuilder.client()
            // Premium пользователи имеют высший приоритет
            .routeWhen(
              toTransport: premiumClientTransport,
              whenCondition: (service, method, context) =>
                  service == 'UserService' &&
                  context?.getHeader('x-tier') == 'premium',
              priority: 100,
              description: 'Premium UserService',
            )
            // Обычные пользователи
            .routeCall(
              calledServiceName: 'UserService',
              toTransport: userClientTransport,
              priority: 50,
            )
            .build();

        // Настраиваем premium сервер
        final premiumEndpoint = RpcResponderEndpoint(
          transport: premiumServerTransport,
        );
        final premiumService = _TestStreamingService(prefix: 'PREMIUM');
        premiumEndpoint.registerServiceContract(premiumService);
        premiumEndpoint.start();

        // Настраиваем обычный сервер
        final userEndpoint = RpcResponderEndpoint(
          transport: userServerTransport,
        );
        final userService = _TestStreamingService(prefix: 'REGULAR');
        userEndpoint.registerServiceContract(userService);
        userEndpoint.start();

        // Клиентский эндпоинт
        final clientEndpoint = RpcCallerEndpoint(transport: router);

        // Act - отправляем запрос с premium заголовком
        final premiumContext = RpcContext.withHeaders({'x-tier': 'premium'});
        final responses = <RpcString>[];

        final responseStream =
            clientEndpoint.serverStream<RpcString, RpcString>(
          serviceName: 'UserService',
          methodName: 'GetNumbers',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: '3'.rpc,
          context: premiumContext,
        );

        await for (final response in responseStream) {
          responses.add(response);
        }

        // Assert - должен попасть в premium сервис
        expect(responses.length, equals(3));
        expect(responses.every((r) => r.value.contains('PREMIUM')), isTrue);
        expect(premiumService.callLog, contains('ServerStream: 3'));
        expect(
          userService.callLog,
          isEmpty,
        ); // Обычный сервис не должен вызываться

        // Cleanup
        await router.close();
        await premiumEndpoint.close();
        await userEndpoint.close();
        await clientEndpoint.close();
      });
    });

    group('Client Stream через Router', () {
      test('должен корректно роутить client stream запрос', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
              calledServiceName: 'PaymentService',
              toTransport: paymentClientTransport,
              priority: 100,
            )
            .build();

        final serverEndpoint = RpcResponderEndpoint(
          transport: paymentServerTransport,
        );
        final testService = _TestStreamingService(
          serviceName: 'PaymentService',
        );
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final clientEndpoint = RpcCallerEndpoint(transport: router);

        // Act
        final requests = ['payment1'.rpc, 'payment2'.rpc, 'payment3'.rpc];
        final clientStreamBuilder =
            clientEndpoint.clientStream<RpcString, RpcString>(
          serviceName: 'PaymentService',
          methodName: 'ProcessPayments',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        );

        final response = await clientStreamBuilder(
          Stream.fromIterable(requests),
        );

        // Assert
        expect(response, equals('Processed 3 requests'.rpc));
        expect(
          testService.callLog,
          contains('ClientStream: payment1, payment2, payment3'),
        );

        await router.close();
        await serverEndpoint.close();
        await clientEndpoint.close();
      });

      test('должен обрабатывать большой поток запросов через роутер', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
              calledServiceName: 'PaymentService',
              toTransport: paymentClientTransport,
              priority: 100,
            )
            .build();

        final serverEndpoint = RpcResponderEndpoint(
          transport: paymentServerTransport,
        );
        final testService = _TestStreamingService(
          serviceName: 'PaymentService',
        );
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final clientEndpoint = RpcCallerEndpoint(transport: router);

        // Act - отправляем большой поток
        const batchSize = 50;
        final requests = List.generate(batchSize, (i) => 'batch_item_$i'.rpc);

        final clientStreamBuilder =
            clientEndpoint.clientStream<RpcString, RpcString>(
          serviceName: 'PaymentService',
          methodName: 'ProcessPayments',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        );

        final response = await clientStreamBuilder(
          Stream.fromIterable(requests),
        );

        // Assert
        expect(response, equals('Processed $batchSize requests'.rpc));
        expect(
          testService.callLog.any((log) => log.contains('batch_item_0')),
          isTrue,
        );
        expect(
          testService.callLog.any(
            (log) => log.contains('batch_item_${batchSize - 1}'),
          ),
          isTrue,
        );

        // Cleanup
        await router.close();
        await serverEndpoint.close();
        await clientEndpoint.close();
      });
    });

    group('🔄 Bidirectional Stream через Router', () {
      test('должен корректно роутить bidirectional stream', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
              calledServiceName: 'ChatService',
              toTransport: userClientTransport,
              priority: 100,
            )
            .build();

        final serverEndpoint = RpcResponderEndpoint(
          transport: userServerTransport,
        );
        final testService = _TestStreamingService(serviceName: 'ChatService');
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final clientEndpoint = RpcCallerEndpoint(transport: router);

        // Act
        final requestController = StreamController<RpcString>();
        final responses = <RpcString>[];

        final responseStream =
            clientEndpoint.bidirectionalStream<RpcString, RpcString>(
          serviceName: 'ChatService',
          methodName: 'Chat',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          requests: requestController.stream,
        );

        final subscription = responseStream.listen(responses.add);

        requestController.add('ping 1'.rpc);
        await Future.delayed(Duration(milliseconds: 1));

        requestController.add('hello world'.rpc);
        await Future.delayed(Duration(milliseconds: 1));

        await requestController.close();
        await Future.delayed(Duration(milliseconds: 1));

        // Assert
        expect(responses.length, greaterThanOrEqualTo(2));
        expect(responses.any((r) => r.value == 'pong'), isTrue);
        expect(
          responses.any((r) => r.value.contains('echo: hello world')),
          isTrue,
        );

        await subscription.cancel();
        await router.close();
        await serverEndpoint.close();
        await clientEndpoint.close();
      });

      test(
        'должен поддерживать множественные bidirectional streams через роутер',
        () async {
          // Arrange
          final router = RpcTransportRouterBuilder.client()
              .routeCall(
                calledServiceName: 'ChatService',
                toTransport: userClientTransport,
                priority: 100,
              )
              .build();

          final serverEndpoint = RpcResponderEndpoint(
            transport: userServerTransport,
          );
          final testService = _TestStreamingService(serviceName: 'ChatService');
          serverEndpoint.registerServiceContract(testService);
          serverEndpoint.start();

          final clientEndpoint = RpcCallerEndpoint(transport: router);

          // Act - создаем два параллельных потока
          final stream1Controller = StreamController<RpcString>();
          final stream2Controller = StreamController<RpcString>();
          final responses1 = <RpcString>[];
          final responses2 = <RpcString>[];

          final responseStream1 =
              clientEndpoint.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'ChatService',
            methodName: 'Chat',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            requests: stream1Controller.stream,
          );

          final responseStream2 =
              clientEndpoint.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'ChatService',
            methodName: 'Chat',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            requests: stream2Controller.stream,
          );

          final subscription1 = responseStream1.listen(responses1.add);
          final subscription2 = responseStream2.listen(responses2.add);

          // Отправляем в оба потока
          stream1Controller.add('stream1_msg'.rpc);
          stream2Controller.add('stream2_msg'.rpc);

          await Future.delayed(Duration(milliseconds: 1));

          // Закрываем потоки
          await stream1Controller.close();
          await stream2Controller.close();
          await Future.delayed(Duration(milliseconds: 1));

          // Assert - оба потока должны получить ответы
          expect(responses1.length, greaterThanOrEqualTo(1));
          expect(responses2.length, greaterThanOrEqualTo(1));

          expect(
            responses1.any((r) => r.value.contains('stream1_msg')),
            isTrue,
          );
          expect(
            responses2.any((r) => r.value.contains('stream2_msg')),
            isTrue,
          );

          // Cleanup
          await subscription1.cancel();
          await subscription2.cancel();
          await router.close();
          await serverEndpoint.close();
          await clientEndpoint.close();
        },
      );
    });

    group('🌊 Mixed Streaming Scenarios', () {
      test(
        'должен обрабатывать все типы стримов одновременно',
        () async {
          // Arrange
          final router = RpcTransportRouterBuilder.client()
              .routeCall(
                calledServiceName: 'MixedService',
                toTransport: userClientTransport,
                priority: 100,
              )
              .build();

          final serverEndpoint = RpcResponderEndpoint(
            transport: userServerTransport,
          );
          final testService = _TestStreamingService(
            serviceName: 'MixedService',
          );
          serverEndpoint.registerServiceContract(testService);
          serverEndpoint.start();

          final clientEndpoint = RpcCallerEndpoint(transport: router);

          try {
            // Act - выполняем все типы стримов параллельно с таймаутами
            final futures = <Future>[];

            // 1. Unary Request
            futures.add(() async {
              final response = await clientEndpoint
                  .unaryRequest<RpcString, RpcString>(
                    serviceName: 'MixedService',
                    methodName: 'Echo',
                    requestCodec: RpcString.codec,
                    responseCodec: RpcString.codec,
                    request: 'unary_test'.rpc,
                  )
                  .timeout(Duration(seconds: 5));
              expect(response.value, equals('Echo: unary_test'));
            }());

            // 2. Server Stream
            futures.add(() async {
              final responses = <RpcString>[];
              final stream = clientEndpoint.serverStream<RpcString, RpcString>(
                serviceName: 'MixedService',
                methodName: 'GetNumbers',
                requestCodec: RpcString.codec,
                responseCodec: RpcString.codec,
                request: '3'.rpc,
              );

              await for (final response in stream.timeout(
                Duration(seconds: 5),
              )) {
                responses.add(response);
              }
              expect(responses.length, equals(3));
            }());

            // 3. Client Stream
            futures.add(() async {
              final clientStreamBuilder =
                  clientEndpoint.clientStream<RpcString, RpcString>(
                serviceName: 'MixedService',
                methodName: 'ProcessPayments',
                requestCodec: RpcString.codec,
                responseCodec: RpcString.codec,
              );

              final requests = ['item1'.rpc, 'item2'.rpc];
              final response = await clientStreamBuilder(
                Stream.fromIterable(requests),
              ).timeout(Duration(seconds: 5));
              expect(response, equals('Processed 2 requests'.rpc));
            }());

            // 4. Bidirectional Stream
            futures.add(() async {
              final requestController = StreamController<RpcString>();
              final responses = <RpcString>[];

              final responseStream =
                  clientEndpoint.bidirectionalStream<RpcString, RpcString>(
                serviceName: 'MixedService',
                methodName: 'Chat',
                requestCodec: RpcString.codec,
                responseCodec: RpcString.codec,
                requests: requestController.stream,
              );

              final subscription = responseStream
                  .timeout(Duration(seconds: 5))
                  .listen(responses.add);

              requestController.add('chat_test'.rpc);
              await Future.delayed(Duration(milliseconds: 1));
              await requestController.close();
              await Future.delayed(Duration(milliseconds: 1));

              expect(responses.length, greaterThanOrEqualTo(1));
              await subscription.cancel();
            }());

            // Assert - все операции должны завершиться успешно
            await Future.wait(futures).timeout(Duration(seconds: 10));
          } finally {
            // Cleanup
            await router.close();
            await serverEndpoint.close();
            await clientEndpoint.close();
          }
        },
        timeout: Timeout(Duration(seconds: 15)),
      ); // Увеличиваем общий таймаут
    });

    group('Error Handling в Streaming', () {
      test('должен обрабатывать ошибки роутинга в streams', () async {
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
              calledServiceName: 'ExistingService',
              toTransport: userClientTransport,
              priority: 100,
            )
            .build();

        Future<void> expectRoutingError(Future<void> Function() action) async {
          final captured = <Object>[];

          bool matches(Object error) {
            final message = error.toString();
            if (error is RpcException ||
                message.contains('NonExistentService') ||
                message.contains('роутинга')) {
              return true;
            }

            return false;
          }

          await runZonedGuarded(
            () async {
              await expectLater(
                () async => action(),
                throwsA(predicate(matches)),
              );
            },
            (error, stack) => captured.add(error),
          );

          for (final error in captured) {
            expect(matches(error), isTrue);
          }
        }

        await expectRoutingError(() {
          return router.sendMetadata(
            1,
            RpcMetadata.forClientRequest(
              'NonExistentService',
              'GetNumbers',
            ),
          );
        });

        await router.close();
      });
    });
  });
}

/// Тестовый сервис, поддерживающий все типы стриминга
final class _TestStreamingService extends RpcResponderContract {
  final List<String> callLog = [];
  final String prefix;

  _TestStreamingService({this.prefix = '', String serviceName = 'UserService'})
      : super(serviceName);

  @override
  void setup() {
    // Unary method
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async {
        callLog.add('Unary: ${request.value}');
        return '${prefix.isNotEmpty ? '$prefix ' : ''}Echo: ${request.value}'
            .rpc;
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Server Stream method
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetNumbers',
      handler: (request, {context}) async* {
        callLog.add('ServerStream: ${request.value}');
        final count = int.tryParse(request.value) ?? 3;
        for (int i = 1; i <= count; i++) {
          yield '${prefix.isNotEmpty ? '$prefix ' : ''}Number $i'.rpc;
          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Client Stream method
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'ProcessPayments',
      handler: (requests, {context}) async {
        final messages = <String>[];
        await for (final request in requests) {
          messages.add(request.value);
        }
        callLog.add('ClientStream: ${messages.join(', ')}');
        return '${prefix.isNotEmpty ? '$prefix ' : ''}Processed ${messages.length} requests'
            .rpc;
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Bidirectional Stream method
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {context}) async* {
        callLog.add('BidirectionalStream started');
        await for (final request in requests) {
          callLog.add('BidirectionalStream: ${request.value}');

          if (request.value.startsWith('ping')) {
            yield '${prefix.isNotEmpty ? '$prefix ' : ''}pong'.rpc;
          } else {
            yield '${prefix.isNotEmpty ? '$prefix ' : ''}echo: ${request.value}'
                .rpc;
          }

          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
