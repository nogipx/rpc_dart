---
status: open
round: (not re-measured) — filed from a READ sweep the owner handed in, re-verified against ff930001 before filing; no round took it
commit: ff930001
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart, packages/core/rpc_dart/lib/src/core/errors.dart]
probe: none — READ, not measured
reason: cost — one rule written seven times across five call shapes; three of the seven have already drifted into different observable behaviour, and one of the drifts silently discards an error message the peer sent
---

# B-64 — the four caller shapes disagree about what ends a call

**Every caller-side shape re-implements "a trailer arrived, turn it into an
exception" by hand.** Seven sites, verified present at `ff930001`:

```
  unary/caller.dart:317              int.tryParse    message ?? ''
  client/caller.dart:111,123         statusCode != '0'   message ?? ''
  server/caller.dart:131             int.tryParse    message ?? 'Unknown error'
  server/caller.dart:184             int.tryParse    message ?? 'Unknown error'
  bidirectional/caller.dart:123      int.tryParse    message ?? 'Unknown error'
  caller_pipeline.dart:816           int.tryParse    message ?? 'Unknown error'
  ping.dart:149                      int.tryParse    message ?? 'Unknown error'
```

Three drifts are already observable, and they are not cosmetic.

## 1. `'Unknown error'` silently destroys the peer's error message

This is the sharpest of the three, and neither the sweep that found it nor the
code notices it. `RpcStatusException.fromTrailer` (`errors.dart:116-130`)
prefers the trailer message and falls back to the one inside
`grpc-status-details-bin`:

```dart
message.isNotEmpty ? message : status.message   // errors.dart:123
```

The fallback is reachable **only when the caller passes an empty string.** Two
of the seven do (`unary/caller.dart:341`, `client/caller.dart:113`); the other
five substitute the literal `'Unknown error'`, which is non-empty, so the branch
at `:123` can never fire for them. A peer that sends its detail in
`grpc-status-details-bin` and leaves `grpc-message` off — legal, and what
`google.rpc.Status` is for — reaches the application as the useful text on a
unary or client-streaming call and as `Unknown error` on the other five.

`details:` is also dropped on that path, because `:117` and `:128` are the only
other returns and neither sets it.

## 2. One of the seven compares the status as a string

`client/caller.dart:111` is `statusCode != '0'`; the other six parse an int.
A peer that spells OK as `00` or ` 0` is a success to six shapes and an error to
client-streaming. Nothing in the repo sends that spelling — the exposure is a
foreign gRPC peer, not rpc_dart talking to itself.

## 3. "OK with no payload" is retryable on one shape and final on another

`unary/caller.dart` holds the response until `grpc-status` arrives and reports
UNAVAILABLE when the stream ends without one. `client/caller.dart:133-143`
reports INTERNAL for the same wire event ("Stream closed without response
payload"). `RpcRetryInterceptor` retries UNAVAILABLE and not INTERNAL, so the
identical truncated response is retried on one shape and surfaced to the
application on the other.

## The completion rule itself is the fourth copy

- `unary/caller.dart:316-335` completes on the STATUS, deliberately not gated on
  `isEndOfStream`, and carries a comment explaining the choice.
- `client/caller.dart:153` completes on the FIRST PAYLOAD.
- `caller_pipeline.dart:809` (`_executeUnaryCall`) returns on the FIRST PAYLOAD.

So a payload followed by an error trailer is an error to the unary caller and a
success to the other two. The unary comment records the history in the code's
own words — the streaming shapes were repaired in round 88 and unary was not,
then unary was repaired and client-streaming was not. **The drift is documented
at one of the copies rather than removed**, which is the same shape B-63 found
at `_ensureUsable`.

## The deadline is waited on four ways

`RpcLongTimer` exists because a dart2js `Timer` past ~24.8 days fires
immediately, and two places use it: `call_scope.dart:267` and
`responder_streams.dart:61,96`. Three caller-side sites still use a bare
`Future.timeout`:

```
  unary/caller.dart:479
  unary/caller.dart:570
  client/caller.dart:249
  ping.dart:238
```

On the web target a deadline beyond that bound expires at once at all four. See
RPC-07. `ping.dart` additionally does not consult the context deadline at all.

## The pre-flight guard covers three shapes of five

`if (!isActive) throw StateError('Endpoint is closed')` is at
`caller_pipeline.dart:321` (`ping`), `:408` (`unaryRequest`) and `:473`
(`serverStream`). `clientStream` and `bidirectionalStream` have no such line.

## What it is NOT

Not a request to collapse the five call shapes — they genuinely differ. What has
no reason to differ is the four rules above: what a trailer means, what an
absent `grpc-message` means, when a call is complete, and how long to wait. A
round taking this should start at #1, which is the only one with a wrong answer
rather than an inconsistent one, and should decide `'Unknown error'` versus `''`
once — `errors.dart:123` says the answer is `''`.

## Owner decision

—

## Item 1 closed — round 415; the lead stays open on the rest

`fromTrailer` now owns the precedence — trailer message, then the message inside
`grpc-status-details-bin`, then `kAbsentTrailerMessage` — and all seven callers
pass the header through empty and all. `grep -rn "Unknown error" packages
--include="*.dart"` returns the constant's declaration and doc prose and no
production call site.

`ping.dart` needed a different edit from the one this lead describes: it does
not call `fromTrailer` at all, so changing its `?? 'Unknown error'` to `?? ''`
would have produced `'Ping failed with status 14: '` and gained nothing. It was
converted to `fromTrailer` instead, and the composed prefix dropped — the status
it names is already on the exception.

**Six of the seven sites have no end-to-end witness.** The factory unit tests
pin the rule and the grep pins the sweep, but only `ServerStreamCaller:142` is
driven against a foreign peer. `server/caller.dart:199`
(`_grpcStatusErrorTransformer`) is PROVEN uncovered: ablating it changed no test
result, which is how it was found.

Still open, and unmeasured: the `!= '0'` string comparison at
`client/caller.dart:111`; UNAVAILABLE against INTERNAL for "OK with no payload";
the completion rule's fourth copy; the four bare `Future.timeout` sites where
`RpcLongTimer` exists; the `Endpoint is closed` pre-flight covering three of
five shapes.
