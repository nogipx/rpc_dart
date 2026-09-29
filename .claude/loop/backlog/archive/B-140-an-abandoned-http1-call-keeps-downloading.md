---
status: closed (round 536)
round: 536
commit: 4ccf1eb1
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: P-169
reason: "CONFIRMED — abandoning changed NOTHING, both arms identical — and FIXED with `http.AbortableRequest`. The lead's claim that one change also closes B-97 is wrong: aborting the request is not a reset, and the server's handler still learns only when it next writes"
---

# B-140 — HTTP/1.1: an abandoned call keeps its request and body read running

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`releaseStreamId` only removes map entries; `_httpClient.send` and `_readBounded` continue to the end; `AbortableRequest` (package:http 1.6) is unused; the `maxActiveStreams` slot is already free, so the ceiling stops bounding real sockets.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:274-278, 354`.

## Why it matters

Cancelled and timed-out calls keep sockets and bandwidth until the server stops.

## Witness a round would build

Cancel 20 slow-streaming calls; count open sockets at the server.

## Fix sketch

Build `AbortableRequest` with an abort trigger completed from `releaseStreamId`
(this also gives the transport a real `IRpcStreamReset`).

## Owner decision

—

## What round 536 measured

```
  arm                          chunks the SERVER wrote   server finished
  call abandoned at 300ms      40 of 40                  true
  CONTROL not abandoned        40 of 40                  true
```

Bench `../probes/P-169-does-abandoning-a-call-stop-the-download.md`. After: `21 of 40 / false`.

**The two arms being identical is the finding.** Read at the SERVER, because the client cannot tell —
an abandoned call drops its future either way and reports nothing locally.

## Fix

`http.AbortableRequest` with a per-stream trigger, registered before the send and completed by
`releaseStreamId`. `package:http` 1.6 was already the resolved version, so no dependency change.

**And a guard that matters as much as the fix**: `RequestAbortedException` is caught on its own branch
above the general handler, so an abandoned call reports NOTHING. The abort is this side's own doing;
reporting it would answer a stream the endpoint has stopped listening to, and logging it at error would
make ordinary teardown look like breakage.

## The claim that one change closes B-97 too is WRONG

Aborting the request closes the socket. The server's HANDLER learns only when it next writes, which is
a different mechanism from a reset frame core can send — so this transport still implements no
`IRpcStreamReset`, and round 488 stopped at the same boundary for the same reason. Advertising the
capability changes what core does on every cancel: a design decision, not a round's.

## Round 488 handed this the abort (B-97)

B-97 removed the phantom `/Unknown/Unknown` POST that every cancel used to fire,
and stopped there deliberately: cancelling still does not STOP the server's
handler, because this transport implements no `IRpcStreamReset`.

Implementing it over `package:http` 1.6's `AbortableRequest` — resolved in the
lockfile, checked — closes both leads with one change: B-140's abandoned call
that keeps downloading is the same abort seen from the receive side.
