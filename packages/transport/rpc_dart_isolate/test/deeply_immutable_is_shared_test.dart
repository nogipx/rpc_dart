// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The README tells users that a `@pragma('vm:deeply-immutable')` message really
// does cross without a copy. Nothing pinned that -- and an unpinned doc claim is
// exactly what rotted the "zero-copy object passing" line this replaced.
//
// Identity is the whole test: the receiver holding the sender's instance is what
// "no copy" means. The CONTROL is what gives it meaning -- the same class with
// the same fields and no pragma must come out COPIED, or the test is measuring
// nothing.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

@pragma('vm:deeply-immutable')
final class Tick {
  const Tick(this.symbol, this.priceCents);

  final String symbol;
  final int priceCents;
}

/// Identical fields, no pragma.
final class PlainTick {
  const PlainTick(this.symbol, this.priceCents);

  final String symbol;
  final int priceCents;
}

/// An ordinary message that CARRIES an annotated one -- the realistic shape.
class Envelope {
  Envelope(this.tick, this.note);

  final Tick tick;
  final String note;
}

/// Carries the identity the worker observed.
class Seen {
  Seen(this.identity);

  final int identity;
}

const _service = 'isolate.DeeplyImmutable';

@pragma('vm:entry-point')
void deeplyImmutableWorkerEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  final contract = _Worker();
  contract.setup();
  endpoint.registerServiceContract(contract);
  endpoint.start();
}

final class _Worker extends RpcResponderContract {
  _Worker() : super(_service, dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    addUnaryMethod<Tick, Seen>(
      methodName: 'Tick',
      handler: (r, {context}) async => Seen(identityHashCode(r)),
    );
    addUnaryMethod<PlainTick, Seen>(
      methodName: 'PlainTick',
      handler: (r, {context}) async => Seen(identityHashCode(r)),
    );
    addUnaryMethod<Envelope, Seen>(
      methodName: 'Envelope',
      handler: (r, {context}) async => Seen(identityHashCode(r.tick)),
    );
  }
}

/// Builds a String at runtime so nothing under test can be a canonicalised
/// compile-time constant, which is shared for a different reason.
String _runtimeString(String value) => String.fromCharCodes(value.codeUnits);

void main() {
  late ({IRpcTransport transport, void Function() kill}) spawned;
  late RpcCallerEndpoint caller;

  setUp(() async {
    spawned = await RpcIsolateTransport.spawn(
      entrypoint: deeplyImmutableWorkerEntrypoint,
      isolateId: 'deeply-immutable',
      debugName: 'DeeplyImmutableWorker',
    );
    caller = RpcCallerEndpoint(transport: spawned.transport);
  });

  tearDown(() async {
    await caller.close();
    spawned.kill();
  });

  test(
    'a deeply-immutable message reaches the worker WITHOUT a copy',
    () async {
      final tick = Tick(_runtimeString('AAPL'), 19999);
      final seen = await caller
          .unaryRequest<Tick, Seen>(
            serviceName: _service,
            methodName: 'Tick',
            request: tick,
          )
          .timeout(const Duration(seconds: 30));

      expect(
        seen.identity,
        identityHashCode(tick),
        reason: 'the annotated class is what makes the hand-off free',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: the same class without the pragma is copied',
    () async {
      // Without this the test above proves nothing: everything would look
      // "shared" if identity happened to survive for some other reason.
      final tick = PlainTick(_runtimeString('AAPL'), 19999);
      final seen = await caller
          .unaryRequest<PlainTick, Seen>(
            serviceName: _service,
            methodName: 'PlainTick',
            request: tick,
          )
          .timeout(const Duration(seconds: 30));

      expect(seen.identity, isNot(identityHashCode(tick)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'an annotated field stays shared inside a message that is copied',
    () async {
      // The realistic shape: the envelope itself is an ordinary class and is
      // copied, but the subgraph the pragma covers is handed over as is.
      final envelope = Envelope(Tick(_runtimeString('MSFT'), 42), 'note');
      final seen = await caller
          .unaryRequest<Envelope, Seen>(
            serviceName: _service,
            methodName: 'Envelope',
            request: envelope,
          )
          .timeout(const Duration(seconds: 30));

      expect(seen.identity, identityHashCode(envelope.tick));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
