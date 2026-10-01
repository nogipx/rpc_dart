---
status: open (562 fixed the double close and refuted the crash; 564 discharged start() re-entrancy; three remain)
round: 564
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-192 — http2 server: onConnectionClosed fires twice; a socket read in the accept path can kill the isolate

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The preface timeout calls `_releaseEndpoint` then `socket.destroy()`, and `socket.done` calls `_releaseEndpoint` again — no idempotency guard; `'${socket.remoteAddress}:${socket.remotePort}'` runs outside the try in the accept callback, and the class's own comment says `remotePort` throws OS Error 22 once the peer is gone; `stop()` closes endpoints serially (N x up to 2 s); `start()` is not re-entrant; `createWithContracts` drops ping and preface options; the "nothing has subscribed yet" comment at `:570-572` is probably false.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart:165-200, 324-349, 362-401, 457-463, 474-475, 535-554, 566-612`.

## Why it matters

Double callbacks to user code; a peer that connects and resets immediately can
end the server process.

## Witness a round would build

Preface timeout 100 ms, connect and send nothing; count `onConnectionClosed`.
Connect-and-RST loop against the accept path.

## Fix sketch

Guard `_releaseEndpoint`; move the address read inside the try; `Future.wait` on
stop.

## Outcome (round 562) — the double close is real; the crash is not

`../rounds/562-one-close-became-two-and-the-crash-was-not-there.md`. Bench
`../probes/P-185-two-paths-release-one-connection.md`.

```
  silent, preface deadline    opened=1  closed=2   ->  closed=1
  speaks h2, closes politely  opened=1  closed=1      (the control)

  200 x connect+RST   escaped=0   then a real call -> ok:x
```

**Claim 1 CONFIRMED and fixed in one line.** `_endpoints` is the registry of live connections, so
`if (!_endpoints.remove(endpoint)) return;` makes the whole release idempotent — endpoint close,
connection map, callback. The polite-close row is the control: without it `closed=1` could mean the
callback had stopped firing.

**Claim 2 REFUTED, and the lead went wrong by quoting the code correctly.** The comment it cites says
`remotePort` throws *"ON CLOSE ... because the peer is already gone"*; the accept-path read happens on a
socket just accepted and not closed. Different states:

```
  just accepted             127.0.0.1:63895
  peer reset, still open    127.0.0.1:63895
  after our own destroy()   THREW SocketException: Socket has been closed
```

The throwing state needs OUR end closed, which is the close path — where `notifyWithoutDying` already
wraps the callbacks. A peer resetting cannot produce it, and the accept path has not closed anything
yet. 200 connect-and-reset cycles put nothing in the zone and the server answered a real call
afterwards, which is the arm that matters since "still running" is a flag a dying isolate still
reports.

**Same shape of error as B-178**, in the same package: a true warning attached to the wrong call.

### `start()` re-entrancy — DISCHARGED by round 560, verified not assumed (round 564)

Read at this sha: `start()` opens with `if (_isRunning || _starting)` and claims `_starting` before its
first await, with the measurement in its own comment. **Both readings of "not re-entrant" are covered** —
two concurrent calls (the second returns early rather than binding a second socket) and a call after
`stop()` (which clears `_starting`, the release round 560's own gate caught as missing in the sibling
package). Nothing left here; it was not merely "possibly a duplicate".

### The three items still open

- `stop()` closes endpoints serially (N x up to 2 s) — a cost; `Future.wait` is the sketch.
- `createWithContracts` drops the ping and preface options.
- The *"nothing has subscribed yet"* comment the lead calls probably false.

`onConnectionOpened` was never double-fired (`opened=1` in every row), so the guard is witnessed on the
close half only.

## Owner decision

—
