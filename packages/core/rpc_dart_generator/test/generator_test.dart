// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

void main() {
  group('rpc_dart_generator', () {
    test(
      'generates caller and responder for unary and server stream',
      () async {
        final packageConfig = await _loadPackageConfig();
        final readerWriter = TestReaderWriter(
          rootPackage: 'rpc_dart_generator',
        );
        await readerWriter.testing.loadIsolateSources();
        const source = r'''
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'input.g.dart';

@RpcService(name: 'Calc')
abstract class ICalc {
  @RpcMethod(name: 'sum')
  Future<Foo> sum(Foo request, {RpcContext? context});

  @RpcMethod(name: 'numbers', kind: RpcMethodKind.serverStream)
  Stream<Foo> numbers(Foo request);
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

        await testBuilder(
          rpcDartBuilder(BuilderOptions({})),
          {'rpc_dart_generator|lib/input.dart': source},
          rootPackage: 'rpc_dart_generator',
          packageConfig: packageConfig,
          readerWriter: readerWriter,
          outputs: {
            'rpc_dart_generator|lib/input.rpc_dart.g.part': decodedMatches(
              allOf([
                contains('class CalcNames'),
                contains('class CalcCaller'),
                contains('abstract class CalcResponder'),
                contains("static const service = 'Calc'"),
                contains("static String instance(String suffix)"),
                contains("static const sum = 'sum'"),
                contains('methodName: CalcNames.sum'),
                contains("addUnaryMethod<Foo, Foo>"),
                contains("addServerStreamMethod<Foo, Foo>"),
                // unidirectional → no Peer class
                isNot(contains('abstract class CalcPeer')),
              ]),
            ),
          },
        );
      },
    );

    test('generates custom method codec overrides', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();

      const source = r'''
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'custom_codec.g.dart';

@RpcService(name: 'Render')
abstract class IRender {
  @RpcMethod(
    name: 'patches',
    kind: RpcMethodKind.serverStream,
    responseCodec: CustomPatchCodec,
  )
  Stream<CustomPatch> patches(PodStreamRequest request);
}

class PodStreamRequest implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => const {};

  factory PodStreamRequest.fromJson(Map<String, dynamic> _) =>
      PodStreamRequest();
}

class CustomPatch implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => const {};
}

class CustomPatchCodec implements IRpcCodec<CustomPatch> {
  const CustomPatchCodec();

  @override
  Uint8List serialize(CustomPatch message) => Uint8List(0);

  @override
  CustomPatch deserialize(Uint8List bytes) => CustomPatch();
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/custom_codec.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/custom_codec.rpc_dart.g.part': decodedMatches(
            allOf([
              contains('class RenderCodecs'),
              contains('static const codecCustomPatch = CustomPatchCodec();'),
              contains('responseCodec: RenderCodecs.codecCustomPatch'),
              contains('requestCodec: RenderCodecs.codecPodStreamRequest'),
            ]),
          ),
        },
      );
    });

    test('generates versioned contract with delegation', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();

      const source = r'''
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'versioned.g.dart';

@RpcService(name: 'Calc')
abstract class ICalc {
  @RpcMethod(name: 'sum')
  Future<Foo> sum(Foo request, {RpcContext? context});

  @RpcMethod(name: 'numbers', kind: RpcMethodKind.serverStream)
  Stream<Foo> numbers(Foo request, {RpcContext? context});
}

@RpcService(name: 'Calc.v2')
abstract class ICalcV2 implements ICalc {
  @override
  @RpcMethod(name: 'sum')
  Future<Bar> sum(Bar request, {RpcContext? context});
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}

class Bar implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/versioned.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/versioned.rpc_dart.g.part': decodedMatches(
            allOf([
              // Base contract
              contains('class CalcNames'),
              contains('class CalcCaller'),
              contains('abstract class CalcResponder'),
              // Versioned contract names
              contains('class CalcV2Names'),
              contains("static const service = 'Calc.v2'"),
              // Versioned caller has parent field
              contains('final CalcCaller _parent'),
              // Versioned caller delegates numbers to parent
              contains('_parent.numbers('),
              // Versioned caller has own sum method
              contains('callUnary<Bar, Bar>'),
              // Versioned responder does NOT implement ICalcV2
              isNot(contains(
                  'abstract class CalcV2Responder extends RpcResponderContract implements')),
              // Versioned responder has abstract sum declaration
              contains('Future<Bar> sum('),
            ]),
          ),
        },
      );
    });

    test('generates @RpcRemoved as deprecated throwing method', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();

      const source = r'''
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'removed.g.dart';

@RpcService(name: 'Calc')
abstract class ICalc {
  @RpcMethod(name: 'sum')
  Future<Foo> sum(Foo request, {RpcContext? context});

  @RpcMethod(name: 'numbers', kind: RpcMethodKind.serverStream)
  Stream<Foo> numbers(Foo request, {RpcContext? context});
}

@RpcService(name: 'Calc.v2')
abstract class ICalcV2 implements ICalc {
  @RpcRemoved('Use multiply() instead')
  @override
  Future<Foo> sum(Foo request, {RpcContext? context});
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/removed.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/removed.rpc_dart.g.part': decodedMatches(
            allOf([
              contains("@Deprecated('Use multiply() instead')"),
              contains('throw UnsupportedError('),
              contains('_parent.numbers('),
              isNot(contains('_parent.sum(')),
            ]),
          ),
        },
      );
    });

    test('generates peer class with onXxx handlers', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'peer.g.dart';

@RpcService(name: 'Chat', kind: RpcServiceKind.peer)
abstract class IChat {
  @RpcMethod(name: 'send')
  Future<Msg> send(Msg request, {RpcContext? context});

  @RpcMethod(name: 'events', kind: RpcMethodKind.serverStream)
  Stream<Msg> events(Msg request);

  @RpcMethod(name: 'bidi', kind: RpcMethodKind.bidirectionalStream)
  Stream<Msg> bidi(Stream<Msg> requests);
}

class Msg implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/peer.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/peer.rpc_dart.g.part': decodedMatches(
            allOf([
              // Peer class is generated, no unidirectional Caller/Responder
              contains('abstract class ChatPeer extends RpcPeerContract'),
              contains('implements IChat'),
              contains('RpcPeerEndpoint endpoint'),
              isNot(contains('class ChatCaller ')),
              isNot(contains('class ChatResponder')),
              // PeerCaller is generated — concrete, caller-only, no onXxx
              contains('class ChatPeerCaller extends RpcPeerContract'),
              contains('void setup() {}'),
              // setup() registers handlers with onXxx names
              contains('handler: onSend'),
              contains('handler: onEvents'),
              contains('handler: onBidi'),
              // Caller methods implement interface (outgoing calls)
              contains('callUnary<Msg, Msg>'),
              contains('callServerStream<Msg, Msg>'),
              contains('callBidirectionalStream<Msg, Msg>'),
              // Abstract handler declarations with on prefix
              contains(
                  'Future<Msg> onSend(Msg request, {RpcContext? context})'),
              contains('Stream<Msg> onEvents(Msg request,'),
              contains('Stream<Msg> onBidi(Stream<Msg> requests,'),
            ]),
          ),
        },
      );
    });

    test('generates PeerCaller without onXxx handlers', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'peer_caller.g.dart';

@RpcService(name: 'Notify', kind: RpcServiceKind.peer)
abstract class INotify {
  @RpcMethod(name: 'push')
  Future<Ack> push(Evt request);

  @RpcMethod(name: 'stream', kind: RpcMethodKind.serverStream)
  Stream<Ack> stream(Evt request);
}

class Evt implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}

class Ack implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/peer_caller.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/peer_caller.rpc_dart.g.part': decodedMatches(
            allOf([
              // NotifyPeer: abstract class with handlers
              contains('abstract class NotifyPeer extends RpcPeerContract'),
              contains(
                  'Future<Ack> onPush(Evt request, {RpcContext? context})'),
              contains(
                  'Stream<Ack> onStream(Evt request, {RpcContext? context})'),
              // NotifyPeerCaller: concrete, implements interface, empty setup, no abstract handlers
              contains('class NotifyPeerCaller extends RpcPeerContract'),
              contains('implements INotify'),
              // empty setup() — differentiates from NotifyPeer whose setup() is non-empty
              contains('void setup() {}'),
              // caller methods are present
              contains('callUnary<Evt, Ack>'),
              contains('callServerStream<Evt, Ack>'),
            ]),
          ),
        },
      );
    });

    test('grpcDescriptor: false (default) omits descriptor', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'no_desc.g.dart';

@RpcService(name: 'Svc')
abstract class ISvc {
  @RpcMethod(name: 'ping')
  Future<Pong> ping(Ping request);
}

class Ping implements IRpcSerializable {
  @override Map<String, dynamic> toJson() => {};
}
class Pong implements IRpcSerializable {
  @override Map<String, dynamic> toJson() => {};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/no_desc.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/no_desc.rpc_dart.g.part': decodedMatches(
            isNot(contains('grpcDescriptor')),
          ),
        },
      );
    });

    test('grpcDescriptor: true generates FileDescriptorProto', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'with_desc.g.dart';

@RpcService(name: 'Svc', grpcDescriptor: true)
abstract class ISvc2 {
  @RpcMethod(name: 'ping')
  Future<Pong2> ping(Ping2 request);
}

class Ping2 implements IRpcSerializable {
  final String id;
  const Ping2({required this.id});
  @override Map<String, dynamic> toJson() => {'id': id};
}
class Pong2 implements IRpcSerializable {
  final String result;
  const Pong2({required this.result});
  @override Map<String, dynamic> toJson() => {'result': result};
}
''';

      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/with_desc.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        outputs: {
          'rpc_dart_generator|lib/with_desc.rpc_dart.g.part': decodedMatches(
            allOf([
              contains('grpcDescriptor'),
              contains('FileDescriptorProto bytes'),
              contains('Uint8List.fromList'),
            ]),
          ),
        },
      );
    });

    test('fails on invalid signature', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const badSource = r'''
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'bad.g.dart';

@RpcService(name: 'Bad')
abstract class BadService {
  @RpcMethod(name: 'broken')
  Foo broken(Foo request);
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      final result = await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/bad.dart': badSource},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
      );

      expect(result.succeeded, isFalse);
      expect(
        result.errors.join('\n'),
        contains('Future'),
        reason: 'fails on invalid signature',
      );
    });
  });
}

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}
