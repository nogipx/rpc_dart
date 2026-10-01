---
status: closed (round 571)
round: 571
commit: 3044897d
release: breaking
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-192
reason: "bench — CONFIRMED as a COUNT at both sites of the class: one unary `Charge` executed THREE times, against a no-retry arm at 1 and a trailers-sent control at 1. Fixed as a SPLIT rather than a replacement, because an existing test requires a forceful `server.stop()` to stay retryable"
---

# B-185 — http2 caller: a clean end without grpc-status becomes retryable UNAVAILABLE

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

A peer that ends the stream cleanly with no trailers (a server bug; the request may have run) is reported UNAVAILABLE, which `RpcRetryInterceptor` retries; grpc-go reports INTERNAL for that and keeps UNAVAILABLE for a lost connection.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1170-1193`. B-86 closed the end-flag half
of this; the status choice was not in it.

## Why it matters

Non-idempotent work retried after it ran.

## Witness a round would build

Raw h2 server: headers + data + END_STREAM, no trailers; status and retry count.

## Fix sketch

INTERNAL for a clean end without status; UNAVAILABLE only for connection loss.

## Outcome (round 571) — confirmed as a COUNT, and fixed as a split

`../rounds/571-the-retry-that-charged-three-times.md`. Bench `P-192`.

```
http2 caller
  WITNESS  no trailers, maxAttempts 3    status 14, ran 3 time(s)  ->  13, 1 time
  ARM      no trailers, no retry         status 14, ran 1 time(s)
  CONTROL  trailers sent, maxAttempts 3  returned "ok", 1 time(s)      unchanged

core channel transport (NOT named by this lead)
  WITNESS  no status, maxAttempts 3      status 14, served 3        ->  13, 1
  CONTROL  a status sent                 returned "ok", 1              unchanged
```

**The count is the finding**: one unary call named `Charge`, executed three times. The ARM
attributes it to the interceptor and the CONTROL says the interceptor is attached and healthy.

**Two sites, swept before the fix** — the http2 caller this lead names, and core's
`RpcChannelTransport`, inherited by websocket, isolate and in-memory.

**A SPLIT, not the replacement the sketch asked for, and an existing test is what forced it.**
`graceful_drain_on_stop_test` requires by name that a forceful `server.stop()` mid-call still fail
"with a prompt, classifiable, **retryable** status", and that ending reaches the same branch. So
http2 now chooses: `goawayReceived || !isOpen` means the connection is going away and UNAVAILABLE
stands; a healthy connection ending without trailers is INTERNAL, which is grpc-go's line. Six
other tests measured that an ERROR is raised at all — their reason strings say so — and each now
records why its value moved.

**The core site has no split** and is always INTERNAL: there is no `goawayReceived` equivalent and
no arm distinguishing a dying channel from a forgetful peer. If a websocket peer can end a stream
status-lessly *because* its socket is going, that case is now non-retryable — probably already a
separate path, not measured.

## Owner decision

—
