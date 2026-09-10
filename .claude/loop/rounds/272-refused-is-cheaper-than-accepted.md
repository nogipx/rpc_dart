---
round: 272
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-22
bench: P-23 — new
commit: yes
---

# Round 272 — refused is cheaper than accepted

## Target

The owner redirected mid-round: *attacks look like the most useful lens — attack
our libraries*. So the memory-efficiency thread this round had opened on
`RpcHttpCallerTransport` (its `_PendingCall.bodyBuffer` is still a `List<int>`,
i.e. ~8 bytes per body byte plus a full copy, the shape the responder side
already fixed) was dropped, and the target became the same file's attack
surface.

It came out of round 271's own reading. 271 fixed the accepted path; nothing had
asked what the REFUSAL path costs. A new lens, RPC-22, refining catalog shape
U-08.

## Hypothesis

`_reject` drains the request body before answering, and its doc comment says
"wall-clock is bounded by [bodyReadTimeout] when set". `bodyReadTimeout` appears
at exactly one call site — around `readBody()` — so the claim may be false, and
a refusal happens before `_pending[streamId]` exists, so nothing counts it
either.

## Before

Sixteen sockets promise a 100000-byte body, send a 5-byte gRPC length prefix and
hold the connection. Same server, `bodyReadTimeout: 500ms`, window 3000ms. One
header differs.

```
arm      content-type       answered in 3s  still draining  pendingRequests
accept   application/grpc   16 of 16 (408)  0               0
refuse   text/plain          0 of 16        16              0
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/refusal_path_has_no_deadline.dart`

An ordinary call still worked in both arms, so this is not a stream-table wedge
like 271's — the damage is a read loop and a file descriptor per socket, held
indefinitely, with no counter anywhere that can see them. `pendingRequests`
reading 0 in BOTH arms is the sharp part: the server's own health check reports
idle while sixteen handler invocations are stuck.

Cost to the attacker: one socket and ~90 bytes each, no valid content-type, no
method, no credentials. **Being refused is cheaper than being accepted**, which
is the inversion the lens is named for.

## Mechanism

The drain is correct and necessary — dart:io tears down a connection whose body
was left unread, which is why `_reject` consumes before answering — but it is
work commanded by an unauthenticated peer on a path with no admission control
and no deadline. The knob that was documented to cover it covered the branch its
author was looking at.

## After

```
arm      content-type       answered in 3s  still draining  pendingRequests
refuse   text/plain         16 of 16        0               0
```

The subscription is CANCELLED on expiry, not merely timed out: `.timeout()` on
the drain future returns the status while the read loop keeps running, which
bounds the handler and nothing else.

## Canary

`test/a_refused_request_has_a_deadline_too_test.dart` — with the deadline
removed the witness failed with

    Expected: empty
      Actual: WhereIterable<String>:['STILL DRAINING' x8]
    every refused slow body must be let go inside the budget

while both GUARDs kept passing: the accepted path still answers 408, and a
refusal INSIDE the budget still gets its 415. That second guard is what stops
the fix from turning every ordinary rejection into a dropped connection.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.
`rpc_dart_http` alone: 120 tests before the new file, 123 after.

## Not fixed

Two things, both filed rather than fixed:

- **B-26** — the accepted path's `readBody().timeout(...)` bounds the WAIT and
  not the work. `.timeout` on a future does not cancel the `await for` inside
  it, so after the 408 the loop keeps consuming and re-filling its builder.
  This round measured the refusal path only; the hypothesis is read off the code
  and the probe to settle it is named in the lead.
- The caller's `List<int>` request buffer, above. A memory amplification on
  outgoing requests, not an attack surface — the peer does not choose that size.

An over-budget refusal now settles by CLOSE rather than by a status line,
because dart:io cannot flush a response on a request whose body was not
consumed. Delivering the status was already best-effort and the code said so;
the trade is stated in the doc comment.

## Links

New lens RPC-22, refining U-08. New bench P-23. New lead B-26. Round 271 is what
this one read.
