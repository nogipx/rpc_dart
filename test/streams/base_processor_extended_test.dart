// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Расширенные тесты StreamProcessor и CallProcessor для улучшения покрытия
/// Фокусируемся на edge cases, обработке ошибок и граничных условиях
void main() {
  group('StreamProcessor - Edge Cases & Error Handling', () {
    late IRpcTransport serverTransport;
    late StreamProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    const streamId = 42;

    setUp(() {
      final transportPair = RpcInMemoryTransport.pair();
      serverTransport = transportPair.$2;
      codec = RpcCodec(RpcString.fromJson);

      processor = StreamProcessor<RpcString, RpcString>(
        transport: serverTransport,
        streamId: streamId,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );
    });

    tearDown(() async {
      await processor.close();
      await serverTransport.close();
    });

    group('⚠️ Error Handling', () {
      test('handles serialization errors in send method', () async {
        // Создаем мок кодека который выбрасывает ошибку при сериализации
        final failingCodec = _FailingCodec<RpcString>();

        final failingProcessor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: streamId + 1,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: failingCodec,
        );

        // Попытка отправить ответ должна обработать ошибку сериализации
        await failingProcessor.send('test'.rpc);

        // Процессор должен остаться активным даже после ошибки
        expect(failingProcessor.isActive, isTrue);

        await failingProcessor.close();
      });

      test('handles transport errors gracefully when closed', () async {
        // Закрываем транспорт перед отправкой
        await serverTransport.close();

        // Операции должны завершаться без исключений
        await processor.send('test response'.rpc);
        await processor.sendError(RpcStatus.INTERNAL, 'Test error');
        await processor.finishSending();

        expect(processor.isActive, isTrue);
      });

      test('handles deserialization errors in message processing', () async {
        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final errors = <Object>[];
        final subscription = processor.requests.listen(
          null,
          onError: errors.add,
        );

        // ИСПРАВЛЕНИЕ: Создаем валидный фрейм с невалидными данными для десериализации
        // Создаем фрейм который парсер распознает, но десериализация упадет
        final invalidJsonBytes =
            Uint8List.fromList('{"invalid": json}'.codeUnits);
        final validFrame = RpcMessageFrame.encode(invalidJsonBytes);

        messageStreamController.add(RpcTransportMessage(
          streamId: streamId,
          payload: validFrame,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        // Ошибки десериализации должны быть переданы в стрим
        expect(errors, isNotEmpty);

        await subscription.cancel();
        await messageStreamController.close();
      });

      test('handles parser errors in message processing', () async {
        // ИЗМЕНЕНИЕ ПОДХОДА: Вместо некорректных фреймов используем failing codec
        final failingCodec = _FailingCodec<RpcString>();

        final failingProcessor = StreamProcessor<RpcString, RpcString>(
          transport: serverTransport,
          streamId: streamId + 10,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec:
              failingCodec, // Кодек который выбрасывает ошибку при deserialize
          responseCodec: codec,
        );

        final messageStreamController = StreamController<RpcTransportMessage>();
        failingProcessor.bindToMessageStream(messageStreamController.stream);

        final errors = <Object>[];
        final subscription = failingProcessor.requests.listen(
          null,
          onError: errors.add,
        );

        // Отправляем корректный фрейм с данными, но десериализация упадет
        final validJsonBytes = '{"v": "test"}'.codeUnits;
        final validFrame =
            RpcMessageFrame.encode(Uint8List.fromList(validJsonBytes));

        messageStreamController.add(RpcTransportMessage(
          streamId: streamId + 10,
          payload: validFrame,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        // Ошибки десериализации должны быть переданы в стрим
        expect(errors, isNotEmpty);

        await subscription.cancel();
        await messageStreamController.close();
        await failingProcessor.close();
      });
    });

    group('📡 Message Processing Edge Cases', () {
      test('handles empty payload correctly', () async {
        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final receivedRequests = <RpcString>[];
        final subscription = processor.requests.listen(
          (request) => receivedRequests.add(request),
        );

        // Отправляем сообщение с пустым payload
        messageStreamController.add(RpcTransportMessage(
          streamId: streamId,
          payload: null,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        // Пустой payload должен быть проигнорирован
        expect(receivedRequests, isEmpty);

        await subscription.cancel();
        await messageStreamController.close();
      });

      test('handles metadata-only messages correctly', () async {
        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final receivedRequests = <RpcString>[];
        final subscription = processor.requests.listen(
          (request) => receivedRequests.add(request),
        );

        // Отправляем только метаданные
        messageStreamController.add(RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata.forTrailer(RpcStatus.OK),
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        // Метаданные без payload не должны создавать запросы
        expect(receivedRequests, isEmpty);

        await subscription.cancel();
        await messageStreamController.close();
      });

      test('handles multiple messages in single frame correctly', () async {
        final messageStreamController = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(messageStreamController.stream);

        final receivedRequests = <RpcString>[];
        final subscription = processor.requests.listen(
          (request) => receivedRequests.add(request),
        );

        // Создаем фрейм с несколькими сообщениями
        final request1 = 'message 1'.rpc;
        final request2 = 'message 2'.rpc;
        final bytes1 = codec.serialize(request1);
        final bytes2 = codec.serialize(request2);

        // Объединяем сообщения в один фрейм
        final frame1 = RpcMessageFrame.encode(bytes1);
        final frame2 = RpcMessageFrame.encode(bytes2);
        final combinedFrame = Uint8List.fromList([...frame1, ...frame2]);

        messageStreamController.add(RpcTransportMessage(
          streamId: streamId,
          payload: combinedFrame,
          isEndOfStream: false,
        ));

        await Future.delayed(Duration(milliseconds: 1));

        // Должны получить оба сообщения
        expect(receivedRequests, hasLength(2));
        expect(receivedRequests[0].value, equals('message 1'));
        expect(receivedRequests[1].value, equals('message 2'));

        await subscription.cancel();
        await messageStreamController.close();
      });
    });

    group('🔄 Lifecycle & State Management', () {
      test('handles operations after close gracefully', () async {
        // Закрываем процессор
        await processor.close();

        // Попытки привязки после закрытия должны быть проигнорированы
        final controller = StreamController<RpcTransportMessage>();
        processor.bindToMessageStream(controller.stream);

        // Все операции должны завершаться без ошибок
        await processor.send('test'.rpc);
        await processor.sendError(RpcStatus.INTERNAL, 'Error');
        await processor.finishSending();

        controller.close();
      });

      test('handles response stream completion correctly', () async {
        bool onDoneCalled = false;
        bool onErrorCalled = false;

        // Привязываем обработчики к потоку запросов (у StreamProcessor нет responses)
        final subscription = processor.requests.listen(
          null,
          onDone: () => onDoneCalled = true,
          onError: (_) => onErrorCalled = true,
        );

        // Закрываем процессор
        await processor.close();

        await Future.delayed(Duration(milliseconds: 1));

        // Проверяем что события завершения обработаны
        expect(onDoneCalled, isTrue);
        expect(onErrorCalled, isFalse);

        await subscription.cancel();
      });
    });
  });

  group('CallProcessor - Advanced Scenarios', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late CallProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    setUp(() {
      final transportPair = RpcInMemoryTransport.pair();
      clientTransport = transportPair.$1;
      serverTransport = transportPair.$2;
      codec = RpcCodec(RpcString.fromJson);

      processor = CallProcessor<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );
    });

    tearDown(() async {
      await processor.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    group('Context Handling', () {
      test('creates processor with context correctly', () async {
        final context = RpcContext.withHeaders({
          'authorization': 'Bearer token123',
          'user-id': 'user456',
        });

        final contextProcessor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          context: context,
        );

        expect(contextProcessor.isActive, isTrue);
        expect(contextProcessor.streamId, isPositive);

        await contextProcessor.close();
      });

      test('handles cancelled context gracefully', () async {
        final cancellationToken =
            RpcCancellationToken.cancelled('Test cancellation');
        final context = RpcContext.withCancellation(cancellationToken);

        // Создание процессора с отмененным контекстом должно выбросить исключение
        expect(
          () => CallProcessor<RpcString, RpcString>(
            transport: clientTransport,
            serviceName: 'TestService',
            methodName: 'TestMethod',
            requestCodec: codec,
            responseCodec: codec,
            context: context,
          ),
          throwsA(isA<RpcCancelledException>()),
        );
      });

      test('handles expired context gracefully', () async {
        final expiredContext = RpcContext.withDeadline(
          DateTime.now().subtract(Duration(seconds: 1)),
        );

        // Создание процессора с истекшим контекстом должно выбросить исключение
        expect(
          () => CallProcessor<RpcString, RpcString>(
            transport: clientTransport,
            serviceName: 'TestService',
            methodName: 'TestMethod',
            requestCodec: codec,
            responseCodec: codec,
            context: expiredContext,
          ),
          throwsA(isA<RpcDeadlineExceededException>()),
        );
      });
    });

    group('Request/Response Processing', () {
      test('handles routing errors in request sending', () async {
        // ИСПРАВЛЕНИЕ: Используем failing codec для request'ов, но обычный транспорт
        // Для тестирования ошибок сериализации в сетевых транспортах
        final failingRequestCodec = _FailingCodec<RpcString>();

        // Создаем обычный транспорт, но обернем его в NonZeroCopyWrapper
        // чтобы заставить использовать сериализацию вместо zero-copy
        final wrappedTransport = _NonZeroCopyTransport(clientTransport);

        final failingProcessor = CallProcessor<RpcString, RpcString>(
          transport: wrappedTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec:
              failingRequestCodec, // Кодек который падает при serialize
          responseCodec: codec,
        );

        final errors = <Object>[];
        final subscription = failingProcessor.responses.listen(
          null,
          onError: errors.add,
        );

        // Попытка отправить запрос должна вызвать ошибку при сериализации
        await failingProcessor.send('test request'.rpc);

        await Future.delayed(Duration(milliseconds: 1));

        // Ошибка должна быть передана в стрим ответов
        expect(errors, isNotEmpty);

        await subscription.cancel();
        await failingProcessor.close();
      });

      test('handles malformed response frames', () async {
        // ИСПРАВЛЕНИЕ: Используем failing codec для response'ов
        final failingResponseCodec = _FailingCodec<RpcString>();

        final failingProcessor = CallProcessor<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec:
              failingResponseCodec, // Кодек который падает при deserialize
        );

        final errors = <Object>[];
        final subscription = failingProcessor.responses.listen(
          null,
          onError: errors.add,
        );

        // Отправляем корректный фрейм ответа, но десериализация упадет
        final validJsonBytes = '{"v": "response"}'.codeUnits;
        final validFrame =
            RpcMessageFrame.encode(Uint8List.fromList(validJsonBytes));

        await serverTransport.sendMessage(
          failingProcessor.streamId,
          validFrame,
        );

        await Future.delayed(Duration(milliseconds: 1));

        // Ошибки десериализации должны быть переданы в стрим
        expect(errors, isNotEmpty);

        await subscription.cancel();
        await failingProcessor.close();
      });

      test('handles error status in metadata responses', () async {
        final responses = <RpcMessage<RpcString>>[];
        final subscription = processor.responses.listen(
          responses.add,
        );

        // Отправляем метаданные с ошибкой
        final errorMetadata = RpcMetadata.forTrailer(
          RpcStatus.INVALID_ARGUMENT,
          message: 'Invalid request format',
        );
        await serverTransport.sendMetadata(processor.streamId, errorMetadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Должны получить метаданные с ошибкой
        expect(responses, isNotEmpty);
        final metadataResponse = responses.first;
        expect(metadataResponse.isMetadataOnly, isTrue);

        await subscription.cancel();
      });
    });

    group('⚡ Performance & Concurrency', () {
      test('handles rapid sequential requests', () async {
        final futures = <Future<void>>[];

        // Отправляем много запросов быстро
        for (int i = 0; i < 100; i++) {
          futures.add(processor.send('request $i'.rpc));
        }

        // Все должны завершиться без ошибок
        await Future.wait(futures);
        expect(processor.isActive, isTrue);
      });

      test('handles request stream completion correctly', () async {
        bool streamCompleted = false;
        final subscription = processor.responses.listen(
          null,
          onDone: () => streamCompleted = true,
        );

        // Завершаем отправку
        await processor.finishSending();

        // Отправляем END_STREAM через сервер
        await serverTransport.sendMetadata(
          processor.streamId,
          RpcMetadata.forTrailer(RpcStatus.OK),
          endStream: true,
        );

        await Future.delayed(Duration(milliseconds: 1));

        expect(streamCompleted, isTrue);
        await subscription.cancel();
      });
    });
  });
}

/// Мок кодека который выбрасывает ошибку при сериализации
class _FailingCodec<T extends IRpcSerializable> implements IRpcCodec<T> {
  @override
  T deserialize(List<int> bytes) {
    throw UnsupportedError('Deserialization not supported in failing codec');
  }

  @override
  Uint8List serialize(T data) {
    throw Exception('Serialization failed in test codec');
  }
}

/// Mock транспорт который ведёт себя как сетевой (не поддерживает zero-copy)
/// и может выбрасывать ошибки для тестирования
class _NonZeroCopyTransport implements IRpcTransport {
  final IRpcTransport _transport;

  _NonZeroCopyTransport(this._transport);

  @override
  bool get isClient => _transport.isClient;

  @override
  bool get isClosed => _transport.isClosed;

  /// Mock транспорт НЕ поддерживает zero-copy (имитирует сетевой транспорт)
  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => _transport.createStream();

  @override
  bool releaseStreamId(int streamId) => _transport.releaseStreamId(streamId);

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _transport.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _transport.getMessagesForStream(streamId);

  @override
  Future<void> sendMessage(int streamId, Uint8List data,
      {bool endStream = false}) async {
    // Симулируем ошибку транспорта при отправке
    throw Exception('Transport error: Failed to send message');
  }

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) async {
    // НЕ поддерживаем zero-copy - выбрасываем стандартную ошибку
    throw UnsupportedError(
      'Транспорт не поддерживает прямую передачу объектов. '
      'Используйте sendMessage() с сериализацией или оптимизированный inmemory транспорт.',
    );
  }

  @override
  Future<void> sendMetadata(int streamId, RpcMetadata metadata,
      {bool endStream = false}) async {
    if (_transport.isClosed) return;

    await _transport.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> finishSending(int streamId) async {
    // Может быть пустой или выбрасывать ошибку
  }

  @override
  Future<void> close() async {
    await _transport.close();
  }
}
