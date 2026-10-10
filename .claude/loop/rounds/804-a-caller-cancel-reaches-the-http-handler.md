---
round: 804
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-14
bench: P-295 — new
commit: yes
severity: S2
release: changelog
---

# Round 804 — a caller cancel reaches the http handler

## Target

B-280, decided by the owner 2026-10-10: I-5 and I-6 hold for http, fix it;
this replaces the B-265 decision to document it. Second of the decided leads
`next` listed (B-275 was round 803).

The class: one server that owns its socket (`RpcHttpServer`) and one
responder transport. Mounted on a foreign shelf server there is no
connection to watch; that stays as documented.

## Hypothesis

The caller's abort closes its connection, and nothing tells the handler,
because shelf passes the handler no signal of the connection's end.

## Before

```
I-6 http, 5 cells (--run-skipped):
  the handler of call 1 never reported "cancelled" within 1000 ms (the
  caller cancelled); it reported: [enter#1(0), received#1(24)]
I-5 http, 4 callerCancels cells and the 40-call cell: never "disposed"
```

## Mechanism

dart:io sees the client's close and neither it nor shelf passes it to the
request (`shelf.io` puts only `connection_info` in the context). The
transport therefore never emits the `x-client-cancelled` frame the http2
and websocket responders send, and the handler's token never fires.

The close itself arrives late: P-295 measured about 2.1 s from a client's
close to a server's `onDone` in one process here, for a raw destroy, a FIN
and an HTTP abort alike. An early reading of two probes as "dart:io does not
read a connection while a request is handled" was wrong (canary 2c below);
the 1.5 s handler in them simply answered before the 2.1 s close.

## Fix

`RpcHttpServer` binds a `ServerSocket` itself and serves it through
`HttpServer.listenOn` behind `PeerWatchingServerSocket`, which wraps each
accepted socket to report when its inbound stream ends. Each request gets
that connection's `Future<void>` in its context (`kRpcHttpPeerGoneKey`); the
responder transport, once it has emitted the request, emits
`x-client-cancelled` for it if the connection ends before the answer.
`stop()` closes the socket (`listenOn` does not). The README's two lines
saying a cancel stays on the caller's side now say what happens.

## After

```
rpc_dart_http a_cancel_reaches_the_handler_test (no proxy):
  cancel -> handler token     2.03 / 2.10 / 2.12 s
I-6 http cells, window widened to 5 s:   pass (about 4.2 s: two TCP hops)
I-5 http cells, windows widened to 8 s:  5 pass
```

At the invariants' own bounds (1 s, 2 s) the http cells still fail, now
because the close arrives late, not because it is lost: they stay KNOWN
FAILING with that reason, and B-284 puts the bound to the owner.

## Canary

1. The server puts no future in the context: the witness fails "the handler
   was not told within 0:00:05.000000 that its caller cancelled".
2. The watcher never reports a close: the same failure.
3. The transport does not emit `x-client-cancelled`: the same failure.
2b/2c. Two canaries against the first design, which read every connection
   ahead of dart:io: propagating the listener's pause to the socket, and
   dropping the separate subscription for a plain watcher on dart:io's own,
   both left the witness green at the same 2.03-2.10 s. The read-ahead was
   not load-bearing and was removed; the watcher is what shipped.
4. A "quiet release" branch (no warning when a gone client's stream is
   released) left the GUARD green when switched off: the pipeline answers
   the cancel itself, so `releaseStreamId` never meets an unanswered gone
   stream. Removed as code no witness reaches; the GUARD stays and
   asserts no warning per cancelled call.

## The verdict questions

1. The CONTROL is the same server and call without the cancel: not
   cancelled in 5 s. Canary 1 is the same build with only the context
   signal removed.
2. Yes: cancelled at ~2.1 s against never.
3. At the handler: its own token fires (an event at the peer, L-11).
4. The control waits 5 s, past the 2.1 s the witness needs.
5. Quoted.
6. Three halves, three failing canaries; two more halves were refuted by
   their canaries and removed.
7. From the numbers.
8. No target dismissed. B-273, B-274 and B-276 are decided and next.
9. A wrapper's pause behaviour read from one probe was wrong: the probe's
   answer came before the event it was meant to see. Already the substance
   of the absence-from-one-probe feedback; none new.
10. Siblings below.
A1. Separate: the server's default policy, the caller's own transport.
A2. Latency: the cancel's signal is a close that arrives ~2.1 s late; the
    witness bounds at 5 s and the record states the latency.
L1. n/a.

## Gate

`melos run analyze`, `test:unit` (16 suites; http +238, conformance +500
~148), `format:check`, `license:check`, `test:web` (15 suites): green.

## Siblings

- channel: clean — has a cancel frame; its I-6 cells pass at 1 s before
  and after
- http: fixed here
- http2: clean — RST_STREAM becomes `x-client-cancelled`; its I-6 cells
  pass at 1 s
- websocket: clean — sends `x-client-cancelled`; its I-6 cells pass at 1 s
- isolate: clean — channel-based cancel frame; its I-6 cells pass at 1 s
- wasm: n/a — no caller connection to close; not in the matrix
- caller: clean — the http caller already aborts its request (B-140,
  `releaseStreamId`); unchanged
- responder: fixed here

## Not fixed

- B-284: the http cancel arrives ~2.1 s after the close on this machine,
  ~4.2 s through the matrix's proxy, past I-6's 1 s and I-5's 2 s; the
  cells stay KNOWN FAILING with that reason. The 2.1 s source is not
  measured, and Linux was not tried.
- A responder transport mounted on another shelf server gets no signal; the
  README says so.
- A client that half-closes its write side after the request would read as
  gone. The rpc_dart caller does not; not measured for others.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`. Bench
`../probes/P-295-when-a-closed-connection-reaches-the-server.md`. Leads
`../backlog/B-280-the-http-responder-is-never-told-the-caller-cancelled.md`
(closed), `../backlog/B-284-the-http-cancel-arrives-after-the-i6-bound.md`
(new).
