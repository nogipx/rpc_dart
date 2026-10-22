// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallObserverInterceptor reports one ending per call, for every call
// shape: succeeded, failed, or cancelled -- a consumer that cancels a stream
// is a call that ended, not one that never did.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Ending {
  _Ending(this.method, this.type);

  final String method;
  final RpcMethodType type;
  int messages = 0;
  int errors = 0;
  RpcCallOutcome? outcome;
}

final class _Recorder extends RpcCallObserverInterceptor<_Ending> {
  final endings = <_Ending>[];
  final _ended = StreamController<_Ending>.broadcast(sync: true);

  Future<_Ending> next(String method) =>
      _ended.stream.firstWhere((e) => e.method == method);

  @override
  _Ending onCallStart(RpcCallInfo call, RpcMethodType type) =>
      _Ending(call.methodName, type);

  @override
  RpcContext contextFor(_Ending state, RpcContext context) =>
      context.withAdditionalHeaders({'x-observed': 'yes'});

  @override
  void onResponseMessage(_Ending state) => state.messages++;

  @override
  void onResponseError(_Ending state, Object error, StackTrace stackTrace) =>
      state.errors++;

  @override
  void onCallEnd(_Ending state, RpcCallOutcome outcome, Duration duration) {
    expect(state.outcome, isNull, reason: 'one ending per call');
    state.outcome = outcome;
    endings.add(state);
    _ended.add(state);
  }
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      handler: (r, {RpcContext? context}) async =>
          RpcString(context?.getHeader('x-observed') ?? 'missing'),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'fails',
      handler: (r, {RpcContext? context}) async =>
          throw RpcStatusException(RpcStatus.notFound, 'nope'),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'three',
      handler: (r, {RpcContext? context}) =>
          Stream.fromIterable(['a', 'b', 'c'].map(RpcString.new)),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'breaks',
      handler: (r, {RpcContext? context}) async* {
        yield const RpcString('a');
        throw RpcStatusException(RpcStatus.dataLoss, 'gone');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endless',
      handler: (r, {RpcContext? context}) =>
          Stream.periodic(const Duration(milliseconds: 5), (_) => r),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) => requests,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late _Recorder recorder;
  late RpcCallerEndpoint caller;

  setUp(() {
    recorder = _Recorder();
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..addInterceptor(recorder)
      ..registerServiceContract(_Svc())
      ..start();
    caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });
  });

  Future<RpcString> unary(String method) => caller.unary(
    serviceName: 'S',
    methodName: method,
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );

  Stream<RpcString> serverStream(String method) => caller.serverStream(
    serviceName: 'S',
    methodName: method,
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );

  test('a unary call succeeds, under the context the observer gave', () async {
    final ended = recorder.next('ok');
    expect((await unary('ok')).value, 'yes');
    final e = await ended;
    expect(e.type, RpcMethodType.unary);
    expect(e.outcome, isA<RpcCallSucceeded>());
  });

  test('a unary call that throws fails with the error', () async {
    final ended = recorder.next('fails');
    await expectLater(unary('fails'), throwsA(isA<RpcStatusException>()));
    final outcome = (await ended).outcome;
    expect(outcome, isA<RpcCallFailed>());
    expect(
      ((outcome! as RpcCallFailed).error as RpcStatusException).statusCode,
      RpcStatus.notFound,
    );
  });

  test('a stream that ends succeeds, with every message seen', () async {
    final ended = recorder.next('three');
    expect(await serverStream('three').length, 3);
    final e = await ended;
    expect(e.type, RpcMethodType.serverStream);
    expect(e.messages, 3);
    expect(e.outcome, isA<RpcCallSucceeded>());
  });

  test('a stream that errors fails with that error', () async {
    final ended = recorder.next('breaks');
    await expectLater(
      serverStream('breaks').toList(),
      throwsA(isA<RpcStatusException>()),
    );
    final e = await ended;
    expect(e.errors, 1);
    expect(e.outcome, isA<RpcCallFailed>());
  });

  test('a stream its consumer cancels ends as cancelled', () async {
    final ended = recorder.next('endless');
    await serverStream('endless').first;
    final e = await ended.timeout(const Duration(seconds: 5));
    expect(e.outcome, isA<RpcCallCancelled>());
  });

  test('a bidirectional stream is observed as one', () async {
    final ended = recorder.next('echo');
    final replies = await caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'S',
          methodName: 'echo',
          requests: Stream.fromIterable([const RpcString('1')]),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();
    expect(replies, hasLength(1));
    final e = await ended;
    expect(e.type, RpcMethodType.bidirectionalStream);
    expect(e.outcome, isA<RpcCallSucceeded>());
  });
}
