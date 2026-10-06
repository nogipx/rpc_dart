---
round: 672
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none — a direct read of reconnect() and of a failed TLS call; `rpc_dart_http/.dart_tool/probe/b152_caller_items.dart`
commit: yes
release: changelog
---

# Round 672 — a handshake with no status

## Target

B-152, http1 in the owner's order: seven items in the HTTP/1.1 caller. Two have
behaviour and were measured (1, 4); five are code shape, decided by reading
(2, 3, 5, 6, 7). All seven in scope.

## Hypothesis

`reconnect()` answers healthy whatever the state, and a TLS failure, not being
a `ClientException`, escapes `_asRpcStatus` with no status.

## Before

```
1. after close: reconnect=healthy  health=closed
4. https to a plain-TCP peer: HandshakeException, NO STATUS
```

A statusless error is invisible to `RpcRetryInterceptor` and the breaker; the
http2 caller reports UNAVAILABLE for the same failure.

## Mechanism

`reconnect()` returned a constant. `_asRpcStatus` mapped `ClientException` only,
and this file compiles for the web, so `dart:io`'s `TlsException` cannot be
named in it.

## Fix

1. `reconnect()` on a closed transport returns `health()` (closed).
2. The component name is a literal; `runtimeType.toString()` is minified on the
   web. Only this file of the four using it compiles for the web.
3. The `on FormatException` around a decode with `allowMalformed: true` is gone;
   the two RegExps are compiled once.
4. `_asRpcStatus`: a redundant `is RpcStatusException` dropped; any other
   `Exception` (the I/O underneath, TLS included) is UNAVAILABLE; an `Error`
   is a bug and passes through.
5. "Call sendMetadata first" now also names the other cause: the request was
   already sent.
6. A comment saying the error body is drained, above a reader that stops at
   8 KiB, now says what the reader does.
7. The nullable `LogScope? _logger` is `LogScope _log` with `LogScope.noop`, 13
   sites, the shape CLAUDE.md prescribes.

## After

```
1. after close: reconnect=closed
4. RpcStatusException status 14: HTTP request to /Svc/M failed: HandshakeException ...
```

## Canary

`packages/transport/rpc_dart_http/test/a_closed_or_tls_failed_caller_says_so_test.dart`:
the closed guard off, `Expected: RpcHealthLevel.closed Actual:
RpcHealthLevel.healthy`; the `Exception` mapping off, `threw
HandshakeException`. Restored: green.

## The verdict questions

1. Yes: one guard each.
2. Yes: healthy against closed; no status against 14.
3. Yes: what the transport returned and threw.
4. Not zero-valued.
5. Yes, quoted.
6. Two behavioural halves, two canaries; the five shape items have none, by
   their nature.
7. Yes.
8. None.

## Gate

`analyze` green; `format:check` clean; `license:check` compliant; the web smoke
(`dart test -p node test/web_smoke_test.dart`) green. `test:unit`: the first run
went red in `rpc_dart_isolate` "a spawn that times out leaves no isolate and no
ports behind" (`Expected: 'exited 0' Actual: 'still running'`), with the
1-minute load at 15.97 after back-to-back gates; green alone, and the next gate
was green in all 15 packages (http +223).

## Not fixed

Nothing on B-152.

## Links

Lead `../backlog/B-152-http1-caller-cleanup-items.md` closed.
Lens `../lenses/RPC-15-remeasure-own-record.md` -- `applied: [..., 672]`.
