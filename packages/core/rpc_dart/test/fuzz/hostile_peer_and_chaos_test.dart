// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Gate-sized slices of the P-225 harnesses, from a fixed seed:
//
// - a hostile peer feeds a server structured and mutated frames, then makes
//   one valid call, which must be answered;
// - concurrent calls of every shape with chaotic handlers and callers must
//   each settle exactly once, and leave no responder behind.
//
// Nothing may reach the zone in either. The full-length runs are in
// `.dart_tool/probe/fuzz_server.dart` and `.dart_tool/probe/chaos_core.dart`.

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Chan implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('closed');
    sent.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _in.close();
  }

  void feed(Uint8List b) {
    if (!_closed) _in.add(b);
  }
}

/// A request's text tells the handler what to do: `<kind>`.
Future<void> _act(String kind, RpcContext? ctx) async {
  switch (kind) {
    case 'delay':
      for (var i = 0; i < 10; i++) {
        ctx?.cancellationToken?.throwIfCancelled();
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
    case 'deaf':
      await Future<void>.delayed(const Duration(milliseconds: 60));
    case 'throw':
      throw StateError('boom');
    case 'status':
      throw RpcStatusException(RpcStatus.notFound, 'nf');
  }
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async {
        await _act(r.value, context);
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        String? first;
        await for (final r in reqs) {
          first ??= r.value;
          if (++n > 2 && first == 'partial') break;
        }
        await _act(first ?? '', context);
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < (r.value == 'flood' ? 200 : 4); i++) {
          if (r.value != 'deaf') context?.cancellationToken?.throwIfCancelled();
          yield '$i'.rpc;
        }
        await _act(r.value, context);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'b',
      handler: (reqs, {RpcContext? context}) async* {
        var i = 0;
        await for (final r in reqs) {
          if (r.value == 'throw' && i > 1) throw StateError('bidi');
          if (r.value == 'partial' && i > 2) return;
          yield r;
          i++;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'a hostile peer cannot stop a server answering',
    () async {
      final rnd = Random(11);
      final zone = <Object>[];
      await runZonedGuarded(() async {
        for (var session = 0; session < 40; session++) {
          final chan = _Chan();
          final transport = RpcChannelTransport.fromChannel(
            channel: chan,
            isClient: false,
            policy: const RpcSecurityPolicy(
              halfOpenStreamTimeout: Duration(milliseconds: 200),
            ),
          );
          final responder = RpcResponderEndpoint(transport: transport)
            ..registerServiceContract(_Svc())
            ..start();
          const methods = ['u', 'c', 's', 'b', 'nope'];
          for (var i = 0; i < 30; i++) {
            final id = [1, 3, 5, 7, 0x7fffffff][rnd.nextInt(5)];
            final frame = switch (rnd.nextInt(5)) {
              0 || 1 => RpcChannelFrame.encodeMetadata(
                streamId: id,
                metadata: RpcMetadata.forClientRequest(
                  'Svc',
                  methods[rnd.nextInt(methods.length)],
                ),
                endOfStream: rnd.nextInt(6) == 0,
              ),
              2 || 3 => RpcChannelFrame.encodeData(
                streamId: id,
                payload: switch (rnd.nextInt(4)) {
                  0 => Uint8List(0),
                  1 => Uint8List.fromList(
                    List.generate(rnd.nextInt(10), (_) => rnd.nextInt(256)),
                  ),
                  2 => Uint8List.sublistView(
                    RpcMessageFrame.encode(_codec.serialize('hello'.rpc)),
                    0,
                    5,
                  ),
                  _ => RpcMessageFrame.encode(_codec.serialize('ok'.rpc)),
                },
                endOfStream: rnd.nextInt(3) == 0,
              ),
              _ => RpcChannelFrame.encodeEndOfStream(id),
            };
            chan.feed(frame);
            if (i % 5 == 4) await Future<void>.delayed(Duration.zero);
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));

          const probe = 1001;
          final before = chan.sent.length;
          chan
            ..feed(
              RpcChannelFrame.encodeMetadata(
                streamId: probe,
                metadata: RpcMetadata.forClientRequest('Svc', 'u'),
              ),
            )
            ..feed(
              RpcChannelFrame.encodeData(
                streamId: probe,
                payload: RpcMessageFrame.encode(_codec.serialize('ping'.rpc)),
                endOfStream: true,
              ),
            );
          String? status;
          for (var w = 0; w < 100 && status == null && !chan.isClosed; w++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            for (final f in chan.sent.skip(before)) {
              final d = RpcChannelFrame.decode(f);
              if (d?.streamId == probe) {
                status ??= d?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
              }
            }
          }
          expect(
            status == '0' || chan.isClosed,
            isTrue,
            reason: 'session $session: the valid call got $status',
          );
          await responder.close();
          await transport.close();
          expect(responder.activeResponderCount, 0, reason: 'session $session');
        }
      }, (e, _) => zone.add(e));
      expect(zone, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'chaotic calls each settle once and leave nothing behind',
    () async {
      final rnd = Random(12);
      final zone = <Object>[];
      await runZonedGuarded(() async {
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Svc())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        const kinds = [
          'ok',
          'ok',
          'delay',
          'throw',
          'status',
          'flood',
          'deaf',
          'partial',
        ];
        final settled = List.filled(150, 0);
        final calls = <Future<void>>[];
        for (var i = 0; i < 150; i++) {
          final kind = kinds[rnd.nextInt(kinds.length)];
          final token = RpcCancellationToken();
          var ctx = RpcContext.withCancellation(token);
          if (rnd.nextInt(3) == 0) {
            ctx = ctx.withTimeout(
              Duration(milliseconds: 10 + rnd.nextInt(100)),
            );
          }
          if (rnd.nextInt(5) == 0) {
            Timer(Duration(milliseconds: rnd.nextInt(60)), token.cancel);
          }
          Stream<RpcString> requests() =>
              Stream.fromIterable(List.filled(1 + rnd.nextInt(5), kind.rpc));
          final Future<Object?> call = switch (i % 4) {
            0 => caller.unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'u',
              request: kind.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            ),
            1 => caller.clientStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'c',
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            )(requests()),
            2 =>
              caller
                  .serverStream<RpcString, RpcString>(
                    serviceName: 'Svc',
                    methodName: 's',
                    request: kind.rpc,
                    requestCodec: _codec,
                    responseCodec: _codec,
                    context: ctx,
                  )
                  .take(rnd.nextInt(6))
                  .toList(),
            _ =>
              caller
                  .bidirectionalStream<RpcString, RpcString>(
                    serviceName: 'Svc',
                    methodName: 'b',
                    requests: requests(),
                    requestCodec: _codec,
                    responseCodec: _codec,
                    context: ctx,
                  )
                  .toList(),
          };
          calls.add(
            call
                .then((_) {}, onError: (Object _) {})
                .whenComplete(() => settled[i]++)
                .timeout(const Duration(seconds: 10)),
          );
        }
        await Future.wait(calls);
        expect(settled.where((n) => n != 1), isEmpty);
        for (var i = 0; i < 50 && responder.activeResponderCount > 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(responder.activeResponderCount, 0);
        await caller.close();
        await responder.close();
      }, (e, _) => zone.add(e));
      expect(zone, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
