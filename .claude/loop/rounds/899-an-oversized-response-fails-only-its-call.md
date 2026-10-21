---
round: 899
verdict: CLEAN
packages: [rpc_dart, rpc_dart_socket, rpc_dart_websocket, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: P-351 — new
commit: yes
release: none
---

# Round 899 — an oversized response fails only its call

## Target

The other direction of round 898, on every transport: I-7's oversize rows
sent only limit + 1, which is how the socket request defect stayed green in
the matrix. Here the caller has the small limit and the response is far past
it. I-7 is one failure, one status; the oversize must also fail only its own
call.

## Hypothesis

A caller refusing a response far past its limit closes while the server is
still writing, and reads UNAVAILABLE, or the refusal takes the connection
with it. Fails if every transport reads 8 at 8 MiB and the next call on the
same connection succeeds.

## Before

P-351:

```
              65537 B   8 MiB    shared, 8 MiB: big / next small
socket        8: 30     8: 30    8: 10 / ok: 10
websocket     8: 30     8: 30    8: 10 / ok: 10
http          8: 30     8: 30    8: 10 / ok: 10
http2         8: 30     8: 30    8: 10 / ok: 10
```

## Mechanism

n/a (CLEAN). The caller's frame channel steps over an oversized frame whose
length it was told and fails only that call (`closeOnOversizedFrame` false on
a client), so it keeps reading and nothing is reset; http and http2 fail the
one response stream.

## After

No change to lib. The I-7 conformance matrix gains `oversizeRequestFar` and
`oversizeResponseFar` (8 MiB), so the size round 898's defect needed is now
in the invariant's own test, on all six members and four shapes. The file
went from 10.7 s to 11.4 s; `+144 ~24`.

## Canary

The socket channel's oversize close switched back to `close()` in place:
I-7 "oversizeRequestFar is status 8: socket | unary", "| clientStream",
"| serverStream" and "| bidi" red, "Expected: <8> Actual: <14>
... Connection reset by peer"; every other cell green. Restored: `+144 ~24`.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`.

## Siblings

- websocket: clean — P-351's websocket file.
- http: clean — P-351's http file.
- http2: clean — P-351's http2 file.
- isolate: clean — I-7's new `oversizeResponseFar` rows, isolate member, green.
- wasm: n/a — not a conformance member; its bridge has no kernel socket to reset.
- channel: clean — I-7's new rows, channel member, green.
- caller: clean — P-351 is the caller refusing.
- responder: clean — round 898 and I-7's `oversizeRequestFar` rows.
- (not a group member) socket: clean — P-351's socket file.

## Not fixed

—

## Links

Round 898, I-7, RPC-25, P-350, P-351.
