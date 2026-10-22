<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Context and metadata

`RpcContext` holds a call's headers, deadline, cancellation token, trace and request ids,
logger, and local values. Pass it as `context:` on any caller method. A responder handler
receives one as its named `context` parameter.

## Rules

- `RpcContext` is immutable. Every `withX` returns a copy. Build one with a
  factory and the `withX` chain.
- Header names are trimmed and lower-cased. A name that does not match
  `^[0-9a-z_.-]+$` after that, or starts with `:`, is DROPPED SILENTLY. So is a
  value containing CR, LF or NUL. `getHeader` lower-cases its argument as well.
- Header values must be printable ASCII (`0x20`-`0x7E`). The context keeps other
  values, but the transport refuses them when sending: the call fails with
  `RpcMetadataViolationException`, an `RpcStatusException(INVALID_ARGUMENT)` (not an
  `ArgumentError`). To send binary or non-ASCII data, base64-encode it
  under a key ending in `-bin`.
- A value that starts or ends with a space or tab is refused before sending,
  with the same `RpcMetadataViolationException` (INVALID_ARGUMENT). Trim values yourself.
- A handler never sees request headers starting with `grpc-`, except
  `grpc-timeout`, `grpc-encoding` and `grpc-accept-encoding`
  (`RpcHeaders.isHiddenFromHandler`). Do not carry application data under a
  `grpc-` name.
- Reserved headers (`RpcHeaders.reserved`: `content-type`, `te`, `user-agent`,
  `grpc-timeout`; and every name starting with `x-rpc-`,
  `RpcHeaders.reservedPrefix`) in user metadata are skipped when sending.
  Check with `RpcHeaders.isReserved(name)`.
- The trace id and request id are always sent from the context's
  `traceId` / `requestId`. An `x-trace-id` or `x-request-id` header you set yourself is
  overwritten. Use `withTraceId` instead.
- Header count, total size, name length and value length are limited by the
  transport's `RpcSecurityPolicy` (`maxHeaders`, `maxMetadataBytes`,
  `maxHeaderNameBytes`, `maxHeaderValueBytes`). See
  [security-and-flow-control.md](security-and-flow-control.md).
- Core does not decide how headers are encoded on the wire. Each transport does.

## Building a context

| API | Result |
| --- | --- |
| `RpcContext.empty()` | no headers, fresh `requestId` |
| `RpcContext.withHeaders(map, {requestId})` | headers (sanitized as above) |
| `RpcContext.withTimeout(d)` / `.withDeadline(t)` | deadline = `DateTime.now() + d` / `t` |
| `RpcContext.withCancellation(token)` | carries an `RpcCancellationToken` |
| `RpcContext.withTraceId(id)` | trace id |
| `ctx.withAdditionalHeaders(map)` | merge headers; existing keys are overwritten |
| `ctx.withBearerAuth(token)` / `ctx.withBasicAuth(user, pass)` | `authorization` header |
| `ctx.withApiKey(key, {headerName = 'x-api-key'})` | the key under `headerName`, treated as a credential whatever the name |
| `ctx.withTimeout(d)` | deadline = `ctx.clock() + d` |
| `ctx.withDeadline / withCancellation / withTraceId / withRequestId / withLog / withClock` | copy with that field replaced |
| `ctx.withValue(key, value)` / `ctx.getValue(key)` | local values under a typed `RpcContextKey<T>` (e.g. `const userKey = RpcContextKey<User>('user')`); NEVER sent on the wire |
| `ctx.getHeader(name)`, `ctx.headers` | read (unmodifiable map) |
| `ctx.deadline`, `ctx.remainingTime`, `ctx.isExpired`, `ctx.isCancelled` | deadline / cancel state |
| `ctx.traceId` (nullable), `ctx.requestId` (always set), `ctx.log` (`LogScope`) | correlation and logging |
| `RpcContext.isContextValid(ctx)` | static: not null, not expired, not cancelled |

`ctx.forward({headers, timeout})` builds the context for a downstream call.
It keeps this context's headers, deadline, token and values, always generates
a new `requestId`, and generates a `traceId` only if this context has none.
`timeout` can shorten the deadline, never extend it. This context's
credentials are dropped: `authorization`, `proxy-authorization`, `x-api-key`,
`cookie`, and a header named by `withApiKey(headerName:)`. `headers` are added
after that, so `forward(headers: {'authorization': 'Bearer <service token>'})`
sends the downstream call's own credential, and passing the caller's on means
naming it: `forward(headers: {'authorization': ctx.getHeader('authorization')!})`.
`RpcContext.sanitize(ctx)` drops the same set.

A call without a `traceId` gets one from the endpoint, on both sides. Set one
with `withTraceId` to join an existing trace, or with
`RpcContext.withTraceId(RpcContext.generateTraceId())` to know it before the
call.

```dart
import 'package:rpc_dart/rpc_dart.dart';

RpcContext outgoing(String token) =>
    RpcContext.empty()
        .withBearerAuth(token)
        .withAdditionalHeaders({'x-tenant': 'acme'})
        .withTimeout(const Duration(seconds: 5));

// Inside a handler: a downstream call keeps the trace, the deadline (at
// most 1 s more of it) and the cancellation, without the caller's
// credentials.
RpcContext downstream(RpcContext incoming) =>
    incoming.forward(timeout: const Duration(seconds: 1));
```

Pitfall when forwarding: `forward` drops only the credential headers listed
above. Another secret the server received, such as a key under a custom header
name that did not come through `withApiKey`, still travels. A context built
from scratch instead loses the deadline and the cancellation.

## Deadlines

- Caller: if the context has a deadline, `remainingTime` is sent as `grpc-timeout`.
  The caller also enforces the deadline locally and fails the call with
  `RpcDeadlineExceededException` (DEADLINE_EXCEEDED).
- Responder: `grpc-timeout` becomes `context.deadline` = server clock +
  timeout. When it passes, the handler's `cancellationToken` is cancelled and
  the call is ended. The `grpc-timeout` header is still readable through
  `getHeader`.
- A responder interceptor may shorten that: a context it passes to `next`
  with an earlier deadline (`call.context.withTimeout(d)`) is enforced the
  same way. A later deadline, or none, does not extend the caller's.
- Deadlines are measured on `RpcContext.monotonicNow`, the default `clock`:
  the wall time read once, advanced by a stopwatch, so a system clock jump
  neither expires a call early nor stretches it. Prefer `withTimeout(d)`; a
  `withDeadline(DateTime.now().add(d))` is on the wall clock and drifts from
  it after a jump. The `RpcContext.withTimeout(d)` factory always uses
  `monotonicNow`. For a fake clock, use
  `RpcContext.empty().withClock(fake).withTimeout(d)`.

## Cancellation

```dart
import 'package:rpc_dart/rpc_dart.dart';

Future<void> cancellable(RpcCallerContract api) async {
  final token = RpcCancellationToken();
  final ctx = RpcContext.withCancellation(token);
  final pending = api.callUnary<String, String>(
    methodName: 'slow',
    request: 'x',
    context: ctx,
  );
  token.cancel('user navigated away');
  try {
    await pending;
  } on RpcCancelledException catch (e) {
    print(e.reason); // 'user navigated away'
  }
}
```

`RpcCancellationToken`: `cancel([reason])` (only the first call has effect), `isCancelled`, `reason`,
`cancelled` (a `Future<void>`), `throwIfCancelled()`, and
`RpcCancellationToken.cancelled([reason])`. A cancelled token stays cancelled.
Do not reuse a context that holds one. On the responder, `context.cancellationToken`
is always set. It fires when the client cancels, when the deadline passes, and when the server drains.

## Responder: per-call scope

Inside a responder handler, `context.callScope` is an `RpcCallScope`. It is
closed when the call ends for any reason. `context.requireCallScope()` returns it, or
throws `RpcStatusException(INTERNAL)` when there is none (client-side or
hand-built contexts).

```dart
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

Stream<int> watch(int id, {RpcContext? context}) {
  final scope = context!.requireCallScope();
  final out = StreamController<int>();
  final timer = scope.use(
    Timer.periodic(const Duration(seconds: 1), (t) => out.add(t.tick)),
    (t) => t.cancel(),
  );
  scope.onDispose(out.close);
  context.log.info('watching $id, timer active: ${timer.isActive}');
  return out.stream;
}
```

`RpcCallScope` methods: `onDispose(cb)` (runs in LIFO order; runs immediately if the scope is already closed),
`use(resource, dispose)`, `track(stream)` (cancelled automatically), `listen(stream, onData, ...)`,
`close()`, `done`, `isClosed`, `remaining`, `cancellationToken`. A disposer that takes longer than
`RpcCallScope.disposerTimeout` (static, default 5 s) is abandoned and logged.
`ctx.values` does not include the scope.

## `RpcContext.sanitize` (static)

`RpcContext.sanitize(ctx)` returns a NEW context for logging. Not for a
downstream call: without the deadline and token, that call outlives the
incoming one (use `forward`). It contains:

- the headers, minus exactly `authorization`, `x-api-key` and `cookie`. Other
  secrets stay, e.g. an API key under a custom `headerName`.
- `traceId`, or `'sanitized-trace'` if there was none.
- a NEW `requestId`. The deadline, cancellation token, values, logger and clock are
  all dropped.

## Pitfalls

- `context.header(...)` and `correlationId` do not exist. Use
  `getHeader(name)` and `traceId` / `requestId`.
- `withHeaders` on the builder MERGES. Nothing removes a header. To drop one,
  build a new context.
- A misspelled header name with a space or other invalid character disappears without an error.
  Check `ctx.headers` if a header seems to be missing.
- `withValue` data never reaches the peer. To send a value, put it in a header.
- `requestId` comes from a non-cryptographic generator: seeded from
  `Random.secure()` on the VM and in browsers, unseeded on Node. Never use it
  as a secret.
