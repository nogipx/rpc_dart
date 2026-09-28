---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-188 — http2 caller: non-200 or wrong content-type fails the call but keeps reading the body

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

A terminal status is emitted but the stream is not reset, so an HTML error page is downloaded and fed to the gRPC parser, producing parse errors and ERROR logs; informational 1xx statuses are also treated as failure.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1268-1298, 1332-1359`.

## Why it matters

Wasted bandwidth and misleading logs behind proxies that answer with HTML.

## Witness a round would build

Server answering 503 with a 1 MiB HTML body.

## Fix sketch

RST after emitting the status; skip 1xx.

## Owner decision

—
