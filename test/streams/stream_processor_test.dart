// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Тесты StreamProcessor следуя принципам Unit Testing:
/// - Тестируем наблюдаемое поведение серверной части
/// - Используем in-memory объекты вместо моков
/// - Проверяем основную функциональность без комплексных сценариев
void main() {
  group('StreamProcessor', () {
    late IRpcTransport serverTransport;
    late StreamProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    const streamId = 42;

    setUp(() {
      // Используем in-memory объекты вместо моков
      final transportPair = RpcInMemoryTransport.pair();
      serverTransport = transportPair.$2; // серверная часть
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

    test('creates processor and initializes correctly', () {
      // Тестируем наблюдаемое поведение - состояние после создания
      expect(processor.isActive, isTrue);
      expect(processor.requests, isA<Stream<RpcString>>());
    });

    test('binds to message stream without errors', () {
      final messageStreamController = StreamController<RpcTransportMessage>();

      // Операция должна завершиться без ошибки
      expect(
          () => processor.bindToMessageStream(messageStreamController.stream),
          returnsNormally);

      messageStreamController.close();
    });

    test('handles multiple bind attempts gracefully', () {
      final controller1 = StreamController<RpcTransportMessage>();
      final controller2 = StreamController<RpcTransportMessage>();

      // Первая привязка
      processor.bindToMessageStream(controller1.stream);

      // Повторная привязка должна быть проигнорирована
      processor.bindToMessageStream(controller2.stream);

      // Процессор должен остаться активным
      expect(processor.isActive, isTrue);

      controller1.close();
      controller2.close();
    });

    test('send method executes without errors', () async {
      final response = 'test response'.rpc;

      // Операция должна завершиться без ошибки
      expect(() => processor.send(response), returnsNormally);

      // Процессор должен остаться активным
      expect(processor.isActive, isTrue);
    });

    test('finishSending executes without errors', () async {
      // Операция должна завершиться без ошибки
      expect(() => processor.finishSending(), returnsNormally);

      // Процессор должен остаться активным
      expect(processor.isActive, isTrue);
    });

    test('sendError executes without errors', () async {
      // Операция должна завершиться без ошибки
      expect(() => processor.sendError(RpcStatus.INTERNAL, 'Test error'),
          returnsNormally);

      // Процессор должен остаться активным
      expect(processor.isActive, isTrue);
    });

    test('close makes processor inactive', () async {
      // Проверяем начальное состояние
      expect(processor.isActive, isTrue);

      // Закрываем процессор
      await processor.close();

      // Проверяем наблюдаемое поведение
      expect(processor.isActive, isFalse);
    });

    test('operations on closed processor are ignored', () async {
      // Закрываем процессор
      await processor.close();
      expect(processor.isActive, isFalse);

      // Попытки операций должны завершаться без ошибки, но ничего не делать
      expect(() => processor.send('should not work'.rpc), returnsNormally);
      expect(() => processor.finishSending(), returnsNormally);
      expect(() => processor.sendError(RpcStatus.INTERNAL, 'Error'),
          returnsNormally);
    });

    test('basic message processing works', () async {
      final messageStreamController = StreamController<RpcTransportMessage>();
      processor.bindToMessageStream(messageStreamController.stream);

      // Создаем коллектор для входящих запросов
      final receivedRequests = <RpcString>[];
      final subscription = processor.requests.listen(
        (request) => receivedRequests.add(request),
      );

      // Отправляем простое сообщение
      final request = 'test request'.rpc;
      final bytes = codec.serialize(request);
      final frame = RpcMessageFrame.encode(bytes);

      messageStreamController.add(RpcTransportMessage(
        streamId: streamId,
        payload: frame,
        isEndOfStream: false,
      ));

      // Ждем обработки
      await Future.delayed(Duration(milliseconds: 100));

      // Проверяем результат
      expect(receivedRequests, hasLength(1));
      expect(receivedRequests.first.value, equals('test request'));

      await subscription.cancel();
      await messageStreamController.close();
    });

    test('handles end of stream message', () async {
      final messageStreamController = StreamController<RpcTransportMessage>();
      processor.bindToMessageStream(messageStreamController.stream);

      final completer = Completer<void>();
      final subscription = processor.requests.listen(
        null,
        onDone: () => completer.complete(),
      );

      // Отправляем END_STREAM сообщение
      messageStreamController.add(RpcTransportMessage(
        streamId: streamId,
        metadata: RpcMetadata.forTrailer(RpcStatus.OK),
        isEndOfStream: true,
      ));

      // Ждем закрытия потока запросов
      await completer.future.timeout(Duration(seconds: 5));

      await subscription.cancel();
      await messageStreamController.close();
    });
  });
}
