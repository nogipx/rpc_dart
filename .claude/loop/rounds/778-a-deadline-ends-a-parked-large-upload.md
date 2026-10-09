---
round: 778
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_http2, rpc_dart_isolate]
lens: RPC-14
bench: P-270 — reused
commit: yes
release: none
---

# Round 778 — a deadline ends a parked large upload

## Target

RPC-14 (a timeout abandons work) over rounds 768-770's credit changes: an
upload of large messages to a handler that never reads parks the sender on
credit, larger than the window. Does the deadline still end the call, and
is the connection whole afterwards?

## Hypothesis

A deadline on a sender parked mid large message does not end the call, or
leaves credit behind that stalls the next upload.

## Before

P-270 with `DEADLINE=1`: a client stream of 6 x 7 MB to a handler that
never reads, deadline 2 s, then a 6 x 7 MB upload on the same connection:

```
  websocket  status 4 after 2017 ms   then upload 6/6
  isolate    status 4 after 2020 ms   then upload 6/6
  http2      status 8 after 439 ms    then upload 6/6
```

## Mechanism

The deadline ends the parked send on the channel transports. On http2 the
un-consumed bound refuses the call first, which C-19 records as the
owner's choice for a handler that stops reading.

## After

n/a.

## Canary

n/a. The follow-up upload needs the credit the first call held.

## The verdict questions

1. One sequence per transport.
2. The deadline's 2 s against http2's earlier refusal shows the bench
   tells the two apart.
3. At the caller and the server.
4. 42 MB after the parked call.
5. n/a.
6. n/a.
7. CLEAN.
8. http2's 8 ruled by C-19.
9. None.
A1. Default policies.
A2. Volume.
L1. Each status names its own cause.

## Gate

n/a — no code change.

## Not fixed

Nothing. http (buffered body) is not a streaming transport.

## Links

Bench `../probes/P-270-large-messages-across-the-transports.md`.
Negative `../checked/C-19-http2-refuses-a-slow-consumer.md`.
