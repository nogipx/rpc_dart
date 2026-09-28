---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
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

## Owner decision

—
