// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Тесты для проверки логирования в StreamProcessor и CallProcessor
/// Покрываем создание процессоров с различными логгерами
void main() {
  group('📝 Base Processor - Logger Integration', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcCodec<RpcString> codec;

    setUp(() {
      final transportPair = RpcInMemoryTransport.pair();
      clientTransport = transportPair.$1;
      serverTransport = transportPair.$2;
      codec = RpcCodec(RpcString.fromJson);
    });

    tearDown(() async {
      await clientTransport.close();
      await serverTransport.close();
    });

    group('🔧 StreamProcessor with Logger', () {
      test('creates processor with custom logger', () async {
        final logger = RpcLogger('TestLogger');

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 42,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('creates processor with null logger', () async {
        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 43,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: null, // Явно передаем null
        );

        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('processes messages with logger enabled', () async {
        final logger = RpcLogger('StreamProcessor');

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 44,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final receivedRequests = <RpcString>[];
        final subscription = processor.requests.listen(
          (request) => receivedRequests.add(request),
        );

        // Отправляем сообщение с логированием
        final request = 'logged request'.rpc;
        final bytes = codec.serialize(request);
        final frame = RpcMessageFrame.encode(bytes);

        messageStreamController.add(RpcTransportMessage(
          streamId: 44,
          payload: frame,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedRequests, hasLength(1));
        expect(receivedRequests.first.value, equals('logged request'));

        await subscription.cancel();
        await messageStreamController.close();
        await processor.close();
      });
    });

    group('CallProcessor with Logger', () {
      test('creates processor with custom logger', () async {
        final logger = RpcLogger('CallLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        expect(processor.isActive, isTrue);
        expect(processor.streamId, isPositive);

        await processor.close();
      });

      test('creates processor with context and logger', () async {
        final context = RpcContext.withHeaders({
          'request-id': 'test-123',
          'user-id': 'user-456',
        });

        final logger = RpcLogger('ContextCallLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          context: context,
          logger: logger,
        );

        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('sends request with detailed logging', () async {
        final logger = RpcLogger('DetailedLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'LogTestService',
          methodName: 'LogTestMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        // Отправляем запрос с логированием
        await processor.send('logged request'.rpc);

        await Future.delayed(Duration(milliseconds: 1));

        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('handles response with logger context', () async {
        final logger = RpcLogger('ResponseLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'ResponseService',
          methodName: 'ResponseMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        final responses = <RpcMessage<RpcString>>[];
        final subscription = processor.responses.listen(
          responses.add,
        );

        // Симулируем ответ от сервера
        final testResponse = 'logged response'.rpc;
        final responseBytes = codec.serialize(testResponse);
        final framedMessage = RpcMessageFrame.encode(responseBytes);

        await serverTransport.sendMessage(processor.streamId, framedMessage);

        await Future.delayed(Duration(milliseconds: 1));

        expect(responses, isNotEmpty);

        await subscription.cancel();
        await processor.close();
      });
    });

    group('🐛 Error Logging Coverage', () {
      test('logs serialization errors correctly', () async {
        final logger = RpcLogger('ErrorLogger');

        // Создаем процессор с failing codec для response
        final failingCodec = _FailingResponseCodec<RpcString>();

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 45,
          serviceName: 'ErrorService',
          methodName: 'ErrorMethod',
          requestCodec: codec,
          responseCodec: failingCodec,
          logger: logger,
        );

        // Попытка отправить ответ должна быть залогирована как ошибка
        await processor.send('will fail'.rpc);

        await Future.delayed(Duration(milliseconds: 1));

        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('logs transport errors correctly', () async {
        final logger = RpcLogger('TransportErrorLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TransportErrorService',
          methodName: 'TransportErrorMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        // Закрываем серверный транспорт для генерации ошибки
        await serverTransport.close();

        // Попытка отправить запрос должна быть залогирована
        await processor.send('will fail transport'.rpc);

        await Future.delayed(Duration(milliseconds: 1));

        await processor.close();
      });

      test('logs parser errors with context', () async {
        final logger = RpcLogger('ParserErrorLogger');

        // ИСПРАВЛЕНИЕ: Используем failing codec для request'ов
        final failingCodec = _FailingRequestCodec<RpcString>();

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 46,
          serviceName: 'ParserErrorService',
          methodName: 'ParserErrorMethod',
          requestCodec: failingCodec, // Кодек который падает при deserialize
          responseCodec: codec,
          logger: logger,
        );

        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final errors = <Object>[];
        final subscription = processor.requests.listen(
          null,
          onError: errors.add,
        );

        // Отправляем корректный фрейм, но десериализация упадет
        final validJsonBytes = '{"v": "test"}'.codeUnits;
        final validFrame =
            RpcMessageFrame.encode(Uint8List.fromList(validJsonBytes));

        messageStreamController.add(RpcTransportMessage(
          streamId: 46,
          payload: validFrame,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        expect(errors, isNotEmpty);

        await subscription.cancel();
        await messageStreamController.close();
        await processor.close();
      });
    });

    group('🔄 Lifecycle Logging', () {
      test('logs processor creation with method path', () async {
        final logger = RpcLogger('LifecycleLogger');

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: 47,
          serviceName: 'LifecycleService',
          methodName: 'LifecycleMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        // Проверяем что процессор создался с логированием
        expect(processor.isActive, isTrue);

        await processor.close();
      });

      test('logs processor closure correctly', () async {
        final logger = RpcLogger('ClosureLogger');

        final processor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'ClosureService',
          methodName: 'ClosureMethod',
          requestCodec: codec,
          responseCodec: codec,
          logger: logger,
        );

        expect(processor.isActive, isTrue);

        // Закрытие должно быть залогировано
        await processor.close();

        expect(processor.isActive, isFalse);
      });
    });
  });
}

/// Мок кодека который выбрасывает ошибку при сериализации ответов
class _FailingResponseCodec<T extends IRpcSerializable>
    implements IRpcCodec<T> {
  @override
  T deserialize(List<int> bytes) {
    // Десериализация работает нормально
    return RpcString('deserialized') as T;
  }

  @override
  Uint8List serialize(T data) {
    // Сериализация всегда падает
    throw Exception('Response serialization failed for logging test');
  }
}

/// Мок кодека который выбрасывает ошибку при десериализации запросов
class _FailingRequestCodec<T extends IRpcSerializable> implements IRpcCodec<T> {
  @override
  T deserialize(List<int> bytes) {
    // Десериализация всегда падает
    throw Exception('Request deserialization failed for logging test');
  }

  @override
  Uint8List serialize(T data) {
    // Сериализация работает нормально
    return Uint8List.fromList('{"v": "serialized"}'.codeUnits);
  }
}
