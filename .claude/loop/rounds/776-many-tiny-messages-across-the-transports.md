---
round: 776
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2, rpc_dart_http, rpc_dart_isolate]
lens: RPC-08
bench: P-274 — new
commit: yes
release: none
---

# Round 776 — many tiny messages across the transports

## Target

The parser's `maxMessagesPerChunk` (1024): a bound on messages decoded
from one inbound chunk, which an honest sender does not see (L-20). Over
HTTP/2 a single 16 KiB DATA frame could carry 3276 empty messages.

## Hypothesis

An honest stream of many tiny messages is refused on some transport.

## Before

P-274, 3000 empty messages each way:

```
  websocket  feed 3000/3000   upload 3000/3000
  http2      feed 3000/3000   upload 3000/3000
  isolate    feed 3000/3000   upload 3000/3000
  http       feed and upload: status 8, "Too many gRPC messages in a single
             chunk: 1025 (max: 1024)"
```

## Mechanism

HTTP/2 hands the parser what package:http2 delivers per DATA frame, and
the sender's frames stayed under the count. HTTP/1.1 parses the whole
buffered body as one chunk; its README states it: "the body reaches the
parser as one chunk, by `maxMessagesPerChunk`. Past either the call fails
with `RESOURCE_EXHAUSTED`", under "Unary methods only".

## After

n/a.

## Canary

n/a.

## The verdict questions

1. The rows differ in transport only.
2. Yes: http's refusal shows the bench reaches the bound.
3. At the caller.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN: three transports carry it; http refuses as its README says.
8. http's refusal ruled by its README, read in this round, and by its
   "Unary methods only" contract.
9. None.
A1. Default policies.
A2. Volume.
L1. The refusal named the per-chunk count.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Probe `../probes/P-274-many-tiny-messages-on-every-transport.md`.
Lesson `../lessons/L-20-a-limit-the-sender-cannot-see.md`.
