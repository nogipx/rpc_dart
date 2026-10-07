<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Streaming

Server streams, client streams and bidirectional streams: how to register
them, call them, end them, cancel them, and how backpressure really works.

## Rules

- Register on an `RpcResponderContract` subclass inside `setup()`; call
  from an `RpcCallerContract` subclass. Each method name can be registered once
  per contract; a second registration throws `RpcStatusException(INTERNAL)`.
- Codecs omitted = zero-copy: objects are passed by reference. That only works
  on a transport with `supportsZeroCopy` (in-memory, isolate). Over any byte
  transport, pass `requestCodec` and `responseCodec` on BOTH sides. See
  [codecs-and-compression.md](codecs-and-compression.md).
- Caller-side server and bidirectional streams are COLD: nothing reaches
  the wire until something listens. A stream nobody listens to is never a call.
- Cancelling the caller's subscription cancels the call. The server's
  handler is told: its context's `cancellationToken` fires and its output
  subscription is cancelled.
- Read `requests` with `await for`. If you use `requests.listen(...)`, you MUST
  pass `onError`. Cancellation and deadline errors are delivered
  on that stream, and an unhandled one is an uncaught async error, which kills
  the isolate.
- Put a deadline on any long-lived call (`RpcContext.withTimeout`). Without
  one, a call that is waiting for a response has no time limit.

## Handler signatures

There are no handler typedefs. The four registration methods take these function types:

| Register | Handler type | Caller method | Caller returns |
| --- | --- | --- | --- |
| `addUnaryMethod<Q, R>` | `Future<R> Function(Q, {RpcContext? context})` | `callUnary` | `Future<R>` |
| `addServerStreamMethod<Q, R>` | `Stream<R> Function(Q, {RpcContext? context})` | `callServerStream` | `Stream<R>` |
| `addClientStreamMethod<Q, R>` | `Future<R> Function(Stream<Q>, {RpcContext? context})` | `callClientStream` | `Future<R>` |
| `addBidirectionalMethod<Q, R>` | `Stream<R> Function(Stream<Q>, {RpcContext? context})` | `callBidirectionalStream` | `Stream<R>` |

All registration methods take named `methodName`, `handler`, `requestCodec`, `responseCodec`
and `description`. All caller methods take `methodName`, `request` or `requests`, the codecs,
and `context`. `context` is always non-null inside a responder handler.

## Example: all three streaming shapes

```dart
import 'package:rpc_dart/rpc_dart.dart';

class TickerResponder extends RpcResponderContract {
  TickerResponder() : super('Ticker');

  @override
  void setup() {
    addServerStreamMethod<int, int>(
      methodName: 'count',
      handler: (n, {context}) async* {
        for (var i = 0; i < n; i++) {
          if (context?.isCancelled ?? false) return;
          yield i;
        }
      },
    );
    addClientStreamMethod<int, int>(
      methodName: 'sum',
      handler: (requests, {context}) async {
        var total = 0;
        await for (final r in requests) {
          total += r;
        }
        return total;
      },
    );
    addBidirectionalMethod<String, String>(
      methodName: 'echo',
      handler: (requests, {context}) => requests.map((s) => s.toUpperCase()),
    );
  }
}

class TickerCaller extends RpcCallerContract {
  TickerCaller(RpcCallerEndpoint endpoint) : super('Ticker', endpoint);

  Stream<int> count(int n, {RpcContext? context}) =>
      callServerStream<int, int>(
        methodName: 'count',
        request: n,
        context: context,
      );

  Future<int> sum(Stream<int> values) =>
      callClientStream<int, int>(methodName: 'sum', requests: values);

  Stream<String> echo(Stream<String> lines) =>
      callBidirectionalStream<String, String>(
        methodName: 'echo',
        requests: lines,
      );
}

Future<void> run() async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(TickerResponder())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  final ticker = TickerCaller(caller);

  final firstThree = await ticker.count(10).take(3).toList(); // [0, 1, 2]
  final total = await ticker.sum(Stream.fromIterable([1, 2, 3])); // 6
  final upper = await ticker.echo(Stream.fromIterable(['a', 'b'])).toList();
  print('$firstThree $total $upper');

  await caller.close();
  await responder.close();
}
```

`take(3)` cancels the subscription after the third item, and that cancels the call on
the server.

## Ending a stream

| Who | How | Effect |
| --- | --- | --- |
| Server stream handler | returned `Stream` completes | caller's stream gets `onDone` (status OK) |
| Server/bidi handler | throws or emits an error | caller's stream gets an error (see [errors-and-resilience.md](errors-and-resilience.md)) |
| Caller (client stream / bidi) | the `requests` stream completes | the server's `requests` stream completes (half-close) |
| Caller (client stream / bidi) | the `requests` stream errors | the call is aborted on the server; the caller sees the error |
| Client-stream handler | returns before reading all requests | the caller gets the response with status OK; the unread requests are dropped |

A client-stream handler that answers early is indistinguishable from one that read
everything. For resumable uploads use bidirectional and acknowledge each committed
message on the response stream.

## Caller-side cancellation

| API | Scope |
| --- | --- |
| `subscription.cancel()` / `take`, `first`, `timeout` | this call |
| `RpcCancellationToken` in `RpcContext.withCancellation(token)`, then `token.cancel(reason)` | every call made with that context |
| `contract.cancelMethod('count', reason)` -> `int` | all active calls of this method on this contract's service |
| `contract.cancelAllMethods(reason)` | all active calls of this contract's service |
| `endpoint.cancelAllMethods(reason)` | every active call on the endpoint |
| `endpoint.cancelRequest(service, method, requestId)` | the calls with that `requestId` |
| `contract.getActiveCallsCount('count')`, `contract.isMethodActive('count')` | inspection only |

A cancelled call that is still being listened to fails with `RpcCancelledException`. Its
`message` is the reason. `endpoint.close()` cancels every active call.

Server streams and bidirectional streams are counted as active only from first listen until done or cancel.
Unary and client-stream calls are counted from when the call is made.

## Backpressure

How backpressure works: credit-based flow control, configured on
`RpcSecurityPolicy`, which belongs to the transport.

- Per-stream window (`flowControlWindowBytes`) and per-connection window
  (`flowControlConnectionWindowBytes`). Both count wire bytes. Credit is
  returned as the receiving application consumes messages, not when they arrive.
- The per-stream grant also carries message credit, equal to the receiver's
  `maxBufferedMessagesPerStream`, so a stream of many small messages parks the
  sender at that depth instead of failing.
- Pausing a caller-side subscription stops credit, so the remote sender's
  `send` waits. An `async*` handler is suspended at `yield`. Resuming releases it.
- If a peer ignores flow control, a stream that holds more than
  `maxBufferedBytes` unconsumed bytes, or more than `maxBufferedMessagesPerStream` messages
  (the only bound zero-copy payloads hit), fails THAT stream with
  `RpcStatusException(RESOURCE_EXHAUSTED)`. Other streams and the connection
  are not affected.
- Bidirectional caller: each outgoing request is sent before the next one is
  pulled from your `requests` stream. Use a `StreamController` or `async*` generator for
  `requests`. Do not pre-buffer.

Details and defaults: [security-and-flow-control.md](security-and-flow-control.md).

## Testing a stream

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('count emits in order then completes', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(TickerResponder())
      ..start();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    await expectLater(
      TickerCaller(caller).count(3),
      emitsInOrder([0, 1, 2, emitsDone]),
    );
  });
}
```

ALWAYS `await expectLater(...)`. If it is not awaited, the test ends first and
the teardown closes the endpoints while the stream is still running. More in [testing.md](testing.md).

## Pitfalls

- No codecs over a byte transport: `callUnary` and `callServerStream` throw
  `ArgumentError('Zero-copy requires a transport that supports zero-copy.')`.
  Passing only one of the two codecs throws `ArgumentError` on every shape.
- `requests.listen(onData)` with no `onError` in a handler crashes the isolate on the first
  client cancel or deadline.
- A server handler cannot be interrupted at a plain `await`. A long handler
  should check `context?.isCancelled` / `context?.isExpired`, or wait on
  `context?.cancellationToken?.cancelled`.
- If the consumer cancels a stream before it finishes, the context's
  cancellation token is cancelled. If you passed your own token, it is now
  cancelled, and every later call that reuses that context fails at once with
  `RpcCancelledException`. Use a fresh context for each call.
- `cancelMethod` reaches only calls currently counted as active. A cold stream that nobody
  has listened to yet is not affected.
- In-flight calls do not survive a reconnect. After `RpcClientConnection`
  is back online, issue them again.
- Server-side, register per-call cleanup on `context.callScope`. It runs when
  the call ends for any reason: success, error, cancel or deadline. See
  [context-and-metadata.md](context-and-metadata.md).
