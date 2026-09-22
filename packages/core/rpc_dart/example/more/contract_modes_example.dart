// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

// Zero-copy models: plain classes.
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

// Serializable models.
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

// Codecs for the serializable types.
final serializableRequestCodec = RpcCodec<SerializableRequest>(
  SerializableRequest.fromJson,
);
final serializableResponseCodec = RpcCodec<SerializableResponse>(
  SerializableResponse.fromJson,
);

//
// RESPONDER CONTRACTS, ONE PER MODE
//
/// Forces zero-copy.
final class ZeroCopyResponder extends RpcResponderContract {
  ZeroCopyResponder()
    : super('ZeroCopyService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  @override
  void setup() {
    // Zero-copy needs no codecs, and they must not be passed.
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'echo',
      handler: (request, {context}) async {
        print('zero-copy handling: $request');
        return ZeroCopyResponse('Zero-copy echo: ${request.message}');
      },
      description: 'Zero-copy echo method',
    );
  }
}

/// Forces serialization.
final class CodecResponder extends RpcResponderContract {
  CodecResponder()
    : super('CodecService', dataTransferMode: RpcDataTransferMode.codec);
  @override
  void setup() {
    // Codec mode requires codecs.
    addUnaryMethod<SerializableRequest, SerializableResponse>(
      methodName: 'echo',
      handler: (request, {context}) async {
        print('codec handling: $request');
        return SerializableResponse('Codec echo: ${request.message}');
      },
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
      description: 'Codec echo method',
    );
  }
}

/// Picks the mode per method.
final class AutoResponder extends RpcResponderContract {
  AutoResponder()
    : super('AutoService', dataTransferMode: RpcDataTransferMode.auto);
  @override
  void setup() {
    // Auto lets zero-copy and codec methods live side by side.
    // Zero-copy: no codecs given.
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'zeroCopyEcho',
      handler: (request, {context}) async {
        print('auto -> zero-copy handling: $request');
        return ZeroCopyResponse('Auto zero-copy echo: ${request.message}');
      },
      description: 'Auto zero-copy echo method',
    );
    // Codec: codecs given.
    addUnaryMethod<SerializableRequest, SerializableResponse>(
      methodName: 'codecEcho',
      handler: (request, {context}) async {
        print('auto -> codec handling: $request');
        return SerializableResponse('Auto codec echo: ${request.message}');
      },
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
      description: 'Auto codec echo method',
    );
  }
}

//
// CALLER CONTRACTS, ONE PER MODE
//
/// Zero-copy caller.
final class ZeroCopyCaller extends RpcCallerContract {
  ZeroCopyCaller(RpcCallerEndpoint endpoint)
    : super(
        'ZeroCopyService',
        endpoint,
        dataTransferMode: RpcDataTransferMode.zeroCopy,
      );
  Future<ZeroCopyResponse> echo(ZeroCopyRequest request) {
    // Codecs must not be passed in zero-copy mode.
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'echo',
      request: request,
    );
  }
}

/// Codec caller.
final class CodecCaller extends RpcCallerContract {
  CodecCaller(RpcCallerEndpoint endpoint)
    : super(
        'CodecService',
        endpoint,
        dataTransferMode: RpcDataTransferMode.codec,
      );
  Future<SerializableResponse> echo(SerializableRequest request) {
    // Codec mode requires codecs.
    return callUnary<SerializableRequest, SerializableResponse>(
      methodName: 'echo',
      request: request,
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
    );
  }
}

/// Auto caller.
final class AutoCaller extends RpcCallerContract {
  AutoCaller(RpcCallerEndpoint endpoint)
    : super(
        'AutoService',
        endpoint,
        dataTransferMode: RpcDataTransferMode.auto,
      );
  Future<ZeroCopyResponse> zeroCopyEcho(ZeroCopyRequest request) {
    // Auto, no codecs given: zero-copy.
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'zeroCopyEcho',
      request: request,
    );
  }

  Future<SerializableResponse> codecEcho(SerializableRequest request) {
    // Auto, codecs given: serialization.
    return callUnary<SerializableRequest, SerializableResponse>(
      methodName: 'codecEcho',
      request: request,
      requestCodec: serializableRequestCodec,
      responseCodec: serializableResponseCodec,
    );
  }
}

//
// THE DEMONSTRATION
//
Future<void> main() async {
  print('Data transfer modes, chosen centrally\n');
  // A connected pair of transports.
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  // The responder endpoint, over serverTransport.
  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
  // The caller endpoint, over clientTransport.
  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
  // Start both.
  responderEndpoint.start();
  callerEndpoint.start();
  await demoZeroCopyMode(responderEndpoint, callerEndpoint);
  await demoCodecMode(responderEndpoint, callerEndpoint);
  await demoAutoMode(responderEndpoint, callerEndpoint);
  await demoFlexibleCodecs(responderEndpoint, callerEndpoint);
  // Close the transports.
  await clientTransport.close();
  await serverTransport.close();
}

Future<void> demoZeroCopyMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== ZERO-COPY MODE ===');
  // Register the zero-copy responder.
  final responder = ZeroCopyResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);
  // Build the zero-copy caller.
  final caller = ZeroCopyCaller(callerEndpoint);
  // Call it.
  try {
    final response = await caller.echo(ZeroCopyRequest('Hello Zero-Copy!'));
    print('result: $response\n');
  } catch (e) {
    print('error: $e\n');
  }
}

Future<void> demoCodecMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== CODEC MODE ===');
  // Register the codec responder.
  final responder = CodecResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);
  // Build the codec caller.
  final caller = CodecCaller(callerEndpoint);
  // Call it.
  try {
    final response = await caller.echo(SerializableRequest('Hello Codec!'));
    print('result: $response\n');
  } catch (e) {
    print('error: $e\n');
  }
}

Future<void> demoAutoMode(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== AUTO MODE ===');
  // Register the auto responder.
  final responder = AutoResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);
  // Build the auto caller.
  final caller = AutoCaller(callerEndpoint);
  // The zero-copy method.
  try {
    final response1 = await caller.zeroCopyEcho(
      ZeroCopyRequest('Hello Auto Zero-Copy!'),
    );
    print('zero-copy result: $response1');
  } catch (e) {
    print('zero-copy error: $e');
  }
  // The codec method.
  try {
    final response2 = await caller.codecEcho(
      SerializableRequest('Hello Auto Codec!'),
    );
    print('codec result: $response2\n');
  } catch (e) {
    print('codec error: $e\n');
  }
}

Future<void> demoFlexibleCodecs(
  RpcResponderEndpoint responderEndpoint,
  RpcCallerEndpoint callerEndpoint,
) async {
  print('=== FLEXIBLE CODEC HANDLING ===');
  // A responder that tolerates codecs either way.
  final responder = FlexibleResponder();
  responder.setup();
  responderEndpoint.registerServiceContract(responder);
  // Two callers, different modes.
  final flexibleCaller = FlexibleCaller(callerEndpoint);
  final codecCaller = CodecCaller(callerEndpoint);
  print('Passing codecs in zero-copy mode (they are ignored):');
  try {
    // This works: the codecs are simply ignored.
    final response = await flexibleCaller.flexibleEcho(
      ZeroCopyRequest('test with ignored codecs'),
    );
    print('ok, the codecs were ignored: $response');
  } catch (e) {
    print('unexpected error: $e');
  }
  print('\nOmitting codecs in codec mode:');
  try {
    // This still fails validation.
    await codecCaller.callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'test',
      request: ZeroCopyRequest('test'),
    );
  } catch (e) {
    print('the expected error: $e');
  }
  print('\nFlexible codec handling works as intended.');
}

final class FlexibleCaller extends RpcCallerContract {
  FlexibleCaller(RpcCallerEndpoint endpoint)
    : super(
        'FlexibleService',
        endpoint,
        dataTransferMode: RpcDataTransferMode.zeroCopy,
      );
  Future<ZeroCopyResponse> flexibleEcho(ZeroCopyRequest request) {
    // Zero-copy mode accepts codec arguments and ignores them.
    return callUnary<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'flexibleEcho',
      request: request,
      // Ignored in zero-copy mode.
      requestCodec: null,
      responseCodec: null,
    );
  }
}

final class FlexibleResponder extends RpcResponderContract {
  FlexibleResponder()
    : super('FlexibleService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  @override
  void setup() {
    // A method that works whichever way the codecs are given.
    addUnaryMethod<ZeroCopyRequest, ZeroCopyResponse>(
      methodName: 'flexibleEcho',
      handler: (request, {context}) async {
        return ZeroCopyResponse('Echo: ${request.message}');
      },
      // Codecs may be passed, and are ignored in zero-copy mode.
      requestCodec: null,
      responseCodec: null,
    );
  }
}
