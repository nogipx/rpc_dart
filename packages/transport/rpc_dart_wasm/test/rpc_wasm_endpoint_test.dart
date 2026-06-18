// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// End-to-end coverage of the WASM transport CONTRACT against a mock bridge.
//
// The real WASM backend ([RpcFlutterWasmBridge] / the js_interop `RpcWasm`
// bootstrap) needs a native host plus a loaded WASM module and therefore can
// only run inside a browser/device. Everything ABOVE the byte boundary is
// runtime-agnostic: [RpcWasmTransport] adapts a byte-only [RpcWasmBridge] to
// rpc_dart's channel transport. These tests substitute the JS bridge with an
// in-memory pair that loops byte frames between a "host" and a "sandbox"
// endpoint -- exactly what the JS bridge does in production -- and prove the
// transport logic (unary, all streaming kinds, ordering, cancellation, error
// propagation, lifecycle) without a browser.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';
import 'package:test/test.dart';

import 'support/fake_wasm_bridge.dart';

// ---------------------------------------------------------------------------
// Shared message types
// ---------------------------------------------------------------------------

class SandboxRequest implements IRpcSerializable {
  final String text;
  SandboxRequest(this.text);

  factory SandboxRequest.fromJson(Map<String, dynamic> json) =>
      SandboxRequest(json['text'] as String);

  @override
  Map<String, dynamic> toJson() => {'text': text};
}

class SandboxResponse implements IRpcSerializable {
  final String text;
  SandboxResponse(this.text);

  factory SandboxResponse.fromJson(Map<String, dynamic> json) =>
      SandboxResponse(json['text'] as String);

  @override
  Map<String, dynamic> toJson() => {'text': text};
}

final _requestCodec = RpcCodec<SandboxRequest>(SandboxRequest.fromJson);
final _responseCodec = RpcCodec<SandboxResponse>(SandboxResponse.fromJson);

// ---------------------------------------------------------------------------
// Contract hosted inside the (mock) sandbox; the host calls it.
// ---------------------------------------------------------------------------

final class SandboxContract extends RpcResponderContract {
  SandboxContract() : super('Sandbox');

  @override
  void setup() {
    addUnaryMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Echo',
      handler: (req, {context}) async => SandboxResponse('echo:${req.text}'),
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addUnaryMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Boom',
      handler: (req, {context}) async => throw RpcStatusException(
        RpcStatus.invalidArgument,
        'bad:${req.text}',
      ),
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addServerStreamMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Count',
      handler: (req, {context}) async* {
        for (var i = 1; i <= 3; i++) {
          yield SandboxResponse('${req.text}:$i');
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addServerStreamMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Forever',
      handler: (req, {context}) async* {
        var i = 0;
        while (true) {
          yield SandboxResponse('${req.text}:${i++}');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addClientStreamMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Join',
      handler: (requests, {context}) async {
        final parts = <String>[];
        await for (final r in requests) {
          parts.add(r.text);
        }
        return SandboxResponse(parts.join('-'));
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addBidirectionalMethod<SandboxRequest, SandboxResponse>(
      methodName: 'Mirror',
      handler: (requests, {context}) async* {
        await for (final r in requests) {
          yield SandboxResponse('m:${r.text}');
        }
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );
  }
}

final class HostCaller extends RpcCallerContract {
  HostCaller(RpcCallerEndpoint endpoint) : super('Sandbox', endpoint);

  Future<SandboxResponse> echo(String text) => callUnary(
    methodName: 'Echo',
    request: SandboxRequest(text),
    requestCodec: _requestCodec,
    responseCodec: _responseCodec,
  );

  Future<SandboxResponse> boom(String text) => callUnary(
    methodName: 'Boom',
    request: SandboxRequest(text),
    requestCodec: _requestCodec,
    responseCodec: _responseCodec,
  );

  Stream<SandboxResponse> count(String text) => callServerStream(
    methodName: 'Count',
    request: SandboxRequest(text),
    requestCodec: _requestCodec,
    responseCodec: _responseCodec,
  );

  Stream<SandboxResponse> forever(String text) => callServerStream(
    methodName: 'Forever',
    request: SandboxRequest(text),
    requestCodec: _requestCodec,
    responseCodec: _responseCodec,
  );

  Future<SandboxResponse> join(List<String> texts) => callClientStream(
    methodName: 'Join',
    requests: Stream.fromIterable(texts.map(SandboxRequest.new)),
    requestCodec: _requestCodec,
    responseCodec: _responseCodec,
  );

  Stream<SandboxResponse> mirror(Stream<String> texts) =>
      callBidirectionalStream(
        methodName: 'Mirror',
        requests: texts.map(SandboxRequest.new),
        requestCodec: _requestCodec,
        responseCodec: _responseCodec,
      );
}

// ---------------------------------------------------------------------------

void main() {
  late FakeWasmBridge hostBridge;
  late FakeWasmBridge sandboxBridge;
  late RpcCallerEndpoint host;
  late RpcResponderEndpoint sandbox;
  late HostCaller caller;

  setUp(() {
    final pair = FakeWasmBridge.pair();
    hostBridge = pair.client;
    sandboxBridge = pair.server;

    // Host side acts as the rpc client (odd stream ids).
    host = RpcCallerEndpoint(
      transport: RpcWasmTransport.fromBridge(
        bridge: hostBridge,
        isClient: true,
      ),
    );

    // Sandbox side acts as the rpc server (even stream ids); this is what
    // `RpcWasm.run` builds inside the real WASM module.
    sandbox = RpcResponderEndpoint(
      transport: RpcWasmTransport.fromBridge(
        bridge: sandboxBridge,
        isClient: false,
      ),
    );
    sandbox.registerServiceContract(SandboxContract());
    sandbox.start();

    caller = HostCaller(host);
  });

  tearDown(() async {
    await host.close();
    await sandbox.close();
  });

  group('unary over WASM bridge', () {
    test('round-trips a request and response', () async {
      final resp = await caller.echo('hi').timeout(const Duration(seconds: 5));
      expect(resp.text, 'echo:hi');
    });

    test('handler error surfaces as typed RpcStatusException', () async {
      await expectLater(
        caller.boom('x'),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.invalidArgument,
          ),
        ),
      );
    });

    test('sequential calls keep responses correctly paired', () async {
      for (var i = 0; i < 5; i++) {
        final resp = await caller.echo('n$i');
        expect(resp.text, 'echo:n$i');
      }
    });

    test('concurrent calls do not cross streams', () async {
      final results = await Future.wait([
        caller.echo('a'),
        caller.echo('b'),
        caller.echo('c'),
      ]).timeout(const Duration(seconds: 5));
      expect(results.map((r) => r.text), ['echo:a', 'echo:b', 'echo:c']);
    });
  });

  group('server stream over WASM bridge', () {
    test('delivers ordered items then completes', () async {
      final items = await caller
          .count('s')
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['s:1', 's:2', 's:3']);
    });

    test('cancellation stops an unbounded stream without deadlock', () async {
      final received = <String>[];
      final sub = caller.forever('go').listen((r) => received.add(r.text));

      // Let a few items flow, then cancel mid-stream.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel().timeout(const Duration(seconds: 5));

      final countAtCancel = received.length;
      expect(countAtCancel, greaterThan(0));

      // No further items must arrive after cancel, and no hang.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(received.length, countAtCancel);
    });
  });

  group('client stream over WASM bridge', () {
    test('aggregates all uploaded items into one response', () async {
      final resp = await caller
          .join(['x', 'y', 'z'])
          .timeout(const Duration(seconds: 5));
      expect(resp.text, 'x-y-z');
    });
  });

  group('bidirectional stream over WASM bridge', () {
    test('mirrors each request in order', () async {
      final ctrl = StreamController<String>();
      final future = caller.mirror(ctrl.stream).take(3).toList();

      await Future<void>.delayed(const Duration(milliseconds: 1));
      ctrl.add('1');
      ctrl.add('2');
      ctrl.add('3');
      await ctrl.close();

      final items = await future.timeout(const Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['m:1', 'm:2', 'm:3']);
    });
  });

  group('lifecycle', () {
    test('use-after-dispose fails cleanly instead of hanging', () async {
      await host.close();
      // The closed endpoint rejects the call synchronously rather than
      // hanging on a bridge that will never reply.
      expect(() => caller.echo('x'), throwsA(isA<StateError>()));
    });

    test('closing the host closes its bridge', () async {
      expect(hostBridge.isClosed, isFalse);
      await host.close();
      expect(hostBridge.isClosed, isTrue);
    });

    test('closing the sandbox closes its bridge', () async {
      expect(sandboxBridge.isClosed, isFalse);
      await sandbox.close();
      expect(sandboxBridge.isClosed, isTrue);
    });
  });
}
