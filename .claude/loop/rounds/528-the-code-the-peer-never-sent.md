---
round: 528
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-23
bench: P-162 — new
commit: yes
release: breaking
severity: S2
---

# Round 528 — the code the peer never sent

## Target

B-132, next in rank order: a local connection reset surfaces as INTERNAL "closed by peer
1002", and raw channel errors are forwarded with no gRPC status.

Lens RPC-23. The narrative beside the code is the mapping table's own doc comment, which
explains 1002 as "protocol or server fault" — a statement about RFC 6455, applied to a
value this platform produces for something else entirely.

## Hypothesis

dart:io sets 1002 itself on a socket error, so a TCP reset is reported as a peer protocol
judgement and is not retried.

## Before

```
  how                            closeCode   the call got
  TCP RESET mid-call             1002        status 13 — WebSocket closed by peer with code 1002
  CONTROL peer vanishes (FIN)    1005        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1001       1001        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1011       1011        status 13 — WebSocket closed by peer with code 1011: server fault
  raw channel error (the web path)           raw WebSocketChannelException
```

Bench `../probes/P-162-what-status-does-each-ending-give.md`.

Both claims CONFIRMED. The reset gives status 13, which `RpcRetryInterceptor` does not
retry, with a message naming a peer that said nothing. The raw error reaches the caller as
the channel package's own exception type — not an `RpcStatusException` at all, so neither a
retry interceptor nor an application catching `RpcStatusException` sees it.

The controls are the two endings that must not move, and they pin the change: a code the
peer really sent stays INTERNAL, a clean goodbye stays UNAVAILABLE. Without them a fix that
moved 1002 could not be told from one that moved the whole table.

**The reset is produced, not simulated.** Dart has no SO_LINGER, so the rig relays bytes,
stops draining the client, and destroys the socket — closing with unread bytes in the
receive queue is what makes the kernel send RST. The arm asserts the close code it got, so a
rig that degraded to FIN cannot read as a pass.

## Mechanism

Read from the SDK rather than inferred. `websocket_impl.dart`'s socket `onError` calls
`_close(WebSocketStatus.protocolError)`, assigns that code to `_closeCode`, and then closes
the controller **without adding an error** — so a socket failure is indistinguishable from
a protocol close, and arrives as 1002.

And this library never sends 1002 itself; its own framing-violation code is 4400, because an
application may only send 1000 or 3000-4999. So between two rpc_dart peers, 1002 has exactly
one source: the local error path.

## After

```
  TCP RESET mid-call             1002        status 14 — WebSocket connection failed with code 1002
  raw channel error (the web path)           RpcStatusException, status 14
```

1002 moved out of the `internal` row and into `unavailable`, with the platform reason
written next to it. The message no longer names the peer for that code — every OTHER code
reaching that point was sent by the peer, which is what makes the special case exact rather
than a hedge.

`onError` now wraps a non-`RpcException` into `RpcStatusException(unavailable, ...)`.
`RpcException`s pass through, because the advisory non-binary-frame report is one and
wrapping it would make a discarded text frame read as a dead connection.

**This TIGHTENS nothing and LOOSENS one thing**: a peer that genuinely sends 1002 is now
retried. That is a bounded cost — the retry policy's attempts, then the same failure — set
against a transient failure that was permanent. It is a behaviour change on a published
package and wants a CHANGELOG line at release.

## Canary

Both halves, separately. 1002 put back on the `internal` row: WITNESS fails
`Expected: <14> Actual: <13>`. `onError` reverted to forwarding verbatim: the web WITNESS
fails `Expected: <Instance of 'RpcStatusException'> ... Actual: WebSocketChannelException`.
The controls pass in both, which is what says each witness reads its own change.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package:
214 passed.

## Not fixed

**Whether retrying a genuine 1002 is right.** The argument here is a base-rate one: this
library cannot send 1002, so a peer sending it is a foreign implementation or a corrupted
path, and neither is common. Nothing measured that.

**The web path was driven in SHAPE, not on a browser.** The witness uses a channel that
raises, which is what `HtmlWebSocketChannel` does; no browser ran. `melos run test:web` does
not cover this file either — it is `@TestOn('vm')` because the reset arm needs dart:io.

**The two halves are one rule and two mechanisms**, and this round fixed both rather than
splitting. They are five lines apart in one file, they are the same claim — a transport
failure must reach the caller as a retryable status — and each has its own canary. The cost
of that choice is that the round is not minimal.

## Links

Lens RPC-23. Bench P-162 (new). Lead B-132 closed, both halves. The mapping table's other
guards live in `close_code_reaches_caller_test.dart`, which this round amended rather than
duplicated.
