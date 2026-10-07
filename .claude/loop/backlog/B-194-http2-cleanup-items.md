---
status: closed (round 698) — cleanup commit by owner decision
round: 698
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-194 — http2: smaller defects and hygiene

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

A terminate retried after it threw, duplicate branches and checks, a typo, a drain signal shared across connections, an unreachable log label, a case-insensitive method, an unmatched open callback, a status computed twice, every message broadcast as well as routed.

## The shape

1. Caller `:1941-1954` — the catch calls `terminate()` again right after
   `terminate()` threw.
2. Caller `:1605-1621` — two consecutive branches return the same `closed` status.
3. Caller `:1389-1396` — the per-parser `maxActiveStreams` check repeats the
   `_reservedStreams` check in `createStream`.
4. Caller `:2018` — typo "Unsupport".
5. `_DrainSignal` is shared across connections; only the reset at `:1868` keeps a
   discarded connection's GOAWAY from marking the new one.
6. Responder `:895, 910` — the label is chosen after `_initialHeadersSent.add`, so
   "trailers-only" is never logged.
7. Responder `:576` — `toUpperCase()` accepts `post`; methods are case-sensitive.
8. Server `:535-554` — if the wrapper throws, `onConnectionOpened` fired with no
   matching Closed.
9. Common `:269-270` — `wireStatusFor(error)` computed twice in one initializer.
10. Caller/responder `_emit` — every message goes to both the router and the
    buffered broadcast, which on the caller exists only to observe errors (same
    shape as the channel-transport lead on double dispatch).

## Why it matters

Hygiene; item 5 is a latent cross-connection bug.

## Witness a round would build

None.

## Fix sketch

One cleanup commit.

## Outcome (cleanup, after round 698)

Done in one cleanup commit, by owner decision, no round: 1 (the second
`terminate()` after one threw is gone), 2 (the two `closed` branches merged),
4 (typo), 6 (the log label is read before the stream is recorded, so
"trailers-only" is reachable), 7 (`:method` compared exactly), 8 (a throwing
wrapper, or a failure before the endpoint exists, now fires
`onConnectionClosed`), 9 (`wireStatusFor` computed once).

Left: 3 (the per-parser `maxActiveStreams` check is a second line behind
`createStream`'s, kept), 5 (the shared drain signal is correct through
`reconnect()`'s reset), 10 (double dispatch is a design question, the same as
the channel transport's).

## Owner decision

2026-10-07: hygiene leads are **done as cleanup commits, without rounds**.
