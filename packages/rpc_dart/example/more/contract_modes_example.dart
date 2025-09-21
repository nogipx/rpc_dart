// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

// Zero-copy модели (простые классы)
class ZeroCopyRequest {
  final String message;
  ZeroCopyRequest(this.message);

  @override
  String toString() => 'ZeroCopyRequest($message)';
}

class ZeroCopyResponse {
  final String reply;
  ZeroCopyResponse(this.reply);

  @override
  String toString() => 'ZeroCopyResponse($reply)';
}

// Сериализуемые модели
class SerializableRequest implements IRpcSerializable {
  final String message;

  SerializableRequest(this.message);

  factory SerializableRequest.fromJson(Map<String, dynamic> json) {
    return SerializableRequest(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  String toString() => 'SerializableRequest($message)';
}

class SerializableResponse implements IRpcSerializable {
  final String reply;

  SerializableResponse(this.reply);

  factory SerializableResponse.fromJson(Map<String, dynamic> json) {
    return SerializableResponse(json['reply'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'reply': reply};

  @override
  String toString() => 'SerializableResponse($reply)';
}

// Кодеки для сериализуемых типов
final serializableRequestCodec = RpcCodec<SerializableRequest>(
  SerializableRequest.fromJson,
);
final serializableResponseCodec = RpcCodec<SerializableResponse>(
  SerializableResponse.fromJson,
);

//
// RESPONDER КОНТРАКТЫ С РАЗНЫМИ РЕЖИМАМИ
//

/// Zero-copy responder - принудительно использует zero-copy режим
final class ZeroCopyResponder extends RpcResponderContract {
  ZeroCopyResponder()
      : super('ZeroCopyService',
            dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    // В zero-copy режиме кодеки не нужны и не должны передаваться
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'echo',
      handler: (request, {context}) async {
        print('🔗 Zero-copy обработка: $request');
        return ZeroCopyResponse('Zero-copy echo: ${request.message}');
      },
      description: 'Zero-copy echo method',
    );
  }
}

/// Codec responder - принудительно использует сериализацию
final class CodecResponder extends RpcResponderContract {
  CodecResponder()
      : super('CodecService', dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    // В codec режиме кодеки обязательны
    addUnaryMethod<SerializableRequest, SerializableResponse>(
      methodName: 'echo',
      handler: (request, {context}) async {
        print('📦 Codec обработка: $request');
        return SerializableResponse('Codec echo: ${request.message}');
      },
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
      description: 'Codec echo method',
    );
  }
}

/// Auto responder - автоматический выбор режима
final class AutoResponder extends RpcResponderContract {
  AutoResponder()
      : super('AutoService', dataTransferMode: RpcDataTransferMode.auto);

  @override
  void setup() {
    // Режим auto позволяет смешивать zero-copy и codec методы

    // Zero-copy метод (кодеки не указаны)
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'zeroCopyEcho',
      handler: (request, {context}) async {
        print('🔗 Auto->Zero-copy обработка: $request');
        return ZeroCopyResponse('Auto zero-copy echo: ${request.message}');
      },
      description: 'Auto zero-copy echo method',
    );

    // Codec метод (кодеки указаны)
    addUnaryMethod<SerializableRequest, SerializableResponse>(
      methodName: 'codecEcho',
      handler: (request, {context}) async {
        print('📦 Auto->Codec обработка: $request');
        return SerializableResponse('Auto codec echo: ${request.message}');
      },
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
      description: 'Auto codec echo method',
    );
  }
}

//
// CALLER КОНТРАКТЫ С РАЗНЫМИ РЕЖИМАМИ
//

/// Zero-copy caller
final class ZeroCopyCaller extends RpcCallerContract {
  ZeroCopyCaller(RpcCallerEndpoint endpoint)
      : super(
          'ZeroCopyService',
          endpoint,
          dataTransferMode: RpcDataTransferMode.zeroCopy,
        );

  Future<ZeroCopyResponse> echo(ZeroCopyRequest request) {
    // В zero-copy режиме кодеки передавать нельзя
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'echo',
      request: request,
    );
  }
}

/// Codec caller
final class CodecCaller extends RpcCallerContract {
  CodecCaller(RpcCallerEndpoint endpoint)
      : super(
          'CodecService',
          endpoint,
          dataTransferMode: RpcDataTransferMode.codec,
        );

  Future<SerializableResponse> echo(SerializableRequest request) {
    // В codec режиме кодеки обязательны
    return callUnary<SerializableRequest, SerializableResponse>(
      methodName: 'echo',
      request: request,
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
    );
  }
}

/// Auto caller
final class AutoCaller extends RpcCallerContract {
  AutoCaller(RpcCallerEndpoint endpoint)
      : super(
          'AutoService',
          endpoint,
          dataTransferMode: RpcDataTransferMode.auto,
        );

  Future<ZeroCopyResponse> zeroCopyEcho(ZeroCopyRequest request) {
    // Auto режим - кодеки не указаны = zero-copy
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'zeroCopyEcho',
      request: request,
    );
  }

  Future<SerializableResponse> codecEcho(SerializableRequest request) {
    // Auto режим - кодеки указаны = codec
    return callUnary<SerializableRequest, SerializableResponse>(
      methodName: 'codecEcho',
      request: request,
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
    );
  }
}

//
// ДЕМОНСТРАЦИЯ
//

Future<void> main() async {
  print(
    '🚀 Демонстрация централизованного управления режимами передачи данных\n',
  );

  // Создаем пару транспортов
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Responder endpoint (использует serverTransport)
  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);

  // Caller endpoint (использует clientTransport)
  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

  // Запускаем endpoints
  responderEndpoint.start();
  callerEndpoint.start();

  await demoZeroCopyMode(responderEndpoint, callerEndpoint);
  await demoCodecMode(responderEndpoint, callerEndpoint);
  await demoAutoMode(responderEndpoint, callerEndpoint);
  await demoFlexibleCodecs(responderEndpoint, callerEndpoint);

  // Закрываем транспорты
  await clientTransport.close();
  await serverTransport.close();
}

Future<void> demoZeroCopyMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== 🔗 ZERO-COPY MODE ===');

  // Регистрируем zero-copy responder
  final responder = ZeroCopyResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);

  // Создаем zero-copy caller
  final caller = ZeroCopyCaller(callerEndpoint);

  // Вызываем метод
  try {
    final response = await caller.echo(ZeroCopyRequest('Hello Zero-Copy!'));
    print('✅ Результат: $response\n');
  } catch (e) {
    print('❌ Ошибка: $e\n');
  }
}

Future<void> demoCodecMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== 📦 CODEC MODE ===');

  // Регистрируем codec responder
  final responder = CodecResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);

  // Создаем codec caller
  final caller = CodecCaller(callerEndpoint);

  // Вызываем метод
  try {
    final response = await caller.echo(SerializableRequest('Hello Codec!'));
    print('✅ Результат: $response\n');
  } catch (e) {
    print('❌ Ошибка: $e\n');
  }
}

Future<void> demoAutoMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== 🔄 AUTO MODE ===');

  // Регистрируем auto responder
  final responder = AutoResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);

  // Создаем auto caller
  final caller = AutoCaller(callerEndpoint);

  // Вызываем zero-copy метод
  try {
    final response1 = await caller.zeroCopyEcho(
      ZeroCopyRequest('Hello Auto Zero-Copy!'),
    );
    print('✅ Zero-copy результат: $response1');
  } catch (e) {
    print('❌ Zero-copy ошибка: $e');
  }

  // Вызываем codec метод
  try {
    final response2 = await caller.codecEcho(
      SerializableRequest('Hello Auto Codec!'),
    );
    print('✅ Codec результат: $response2\n');
  } catch (e) {
    print('❌ Codec ошибка: $e\n');
  }
}

Future<void> demoFlexibleCodecs(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== 🧩 FLEXIBLE CODEC HANDLING ===');

  // Создаем responder который поддерживает гибкие кодеки
  final responder = FlexibleResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);

  // Создаем caller'ы с разными режимами
  final flexibleCaller = FlexibleCaller(callerEndpoint);
  final codecCaller = CodecCaller(callerEndpoint);

  print('Передача кодеков в zero-copy режиме (они будут проигнорированы):');
  try {
    // Теперь это работает! Кодеки просто игнорируются
    final response = await flexibleCaller.flexibleEcho(
      ZeroCopyRequest('test with ignored codecs'),
    );
    print('✅ Успешно! Кодеки проигнорированы: $response');
  } catch (e) {
    print('❌ Неожиданная ошибка: $e');
  }

  print('\nПопытка не передать кодеки в codec режиме:');
  try {
    // Это по-прежнему вызовет ошибку валидации
    await codecCaller.callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'test',
      request: ZeroCopyRequest('test'),
    );
  } catch (e) {
    print('❌ Ожидаемая ошибка: $e');
  }

  print('\n✅ Гибкое управление кодеками работает корректно!');
}

final class FlexibleCaller extends RpcCallerContract {
  FlexibleCaller(RpcCallerEndpoint endpoint)
      : super(
          'FlexibleService',
          endpoint,
          dataTransferMode: RpcDataTransferMode.zeroCopy,
        );

  Future<ZeroCopyResponse> flexibleEcho(ZeroCopyRequest request) {
    // Демонстрируем что в zero-copy режиме можно передать кодеки
    // Они будут проигнорированы системой
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'flexibleEcho',
      request: request,
      // Эти кодеки будут проигнорированы в zero-copy режиме
      requestCodec: null,
      responseCodec: null,
    );
  }
}

final class FlexibleResponder extends RpcResponderContract {
  FlexibleResponder()
      : super('FlexibleService',
            dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    // Регистрируем метод который может работать с любыми кодеками
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'flexibleEcho',
      handler: (request, {context}) async {
        return ZeroCopyResponse('Echo: ${request.message}');
      },
      // Можно указать кодеки, но они будут проигнорированы в zero-copy режиме
      requestCodec: null,
      responseCodec: null,
    );
  }
}
