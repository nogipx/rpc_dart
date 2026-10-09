---
round: 532
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: P-165 — new
commit: yes
severity: S3
---

# Round 532 — a probe is not a failure

## Target

B-136, next in rank order: a plain HTTP request to the websocket server is logged as a
connection error.

Lens RPC-22 — the refusal path is reachable by anyone. Here the refusal works and it is the
REPORTING that is wrong: the cheapest possible request turns into an operator-facing error, at
whatever rate the requester chooses.

## Hypothesis

Every request goes to `WebSocketTransformer`, which answers 400 and errors the connections
stream, so each health check produces an error log and an `onConnectionError`.

## Before

```
  arm                            error logs   onConnectionError   peer saw
  10 plain GETs                  10           10                  400
  CONTROL 10 real handshakes     0            0                   upgraded
```

Bench `../probes/P-165-what-does-a-health-check-cost.md`.

CONFIRMED, one for one. The peer column is what keeps the fix honest: the answer was already
correct, so only the noise may move.

## Mechanism

Read from the SDK. `_WebSocketTransformerImpl._upgrade` sends 400 for a non-upgrade request and
returns `Future.error(WebSocketException(...))`, and `bind` does `.catchError(_controller.addError)`
— so the failure lands on the transformer's OUTPUT stream, which is the server's `connections`
stream, which reaches `onError`.

## After

```
  10 plain GETs                  0            0                   400
```

Non-upgrade requests are answered before the transformer sees them. Two things fell out of
getting there:

**Order matters, and the first attempt got it wrong.** Checking the shape before the
origin/`allowUpgrade` gate answers a cross-origin probe `400` — "wrong shape" — about a request
refused on identity. `origin_guard_test` pins 403 there, and it failed. The gate runs first.

**The drain is load-bearing, and the first attempt removed it.** Answering without draining
looked like a strict improvement: it avoids putting a bounded hold on every server rather than
only the gated ones. But `await response.close()` on a request with an unread body does not
complete, so the peer got nothing —
`a_refused_upgrade_has_a_deadline_test.dart` caught it. The existing bounded drain is reused for
both statuses.

Also pre-normalised: `allowedOrigins` is lower-cased once at construction instead of per
handshake. A hygiene change with no witness of its own; equivalence is what
`origin_guard_test`'s case-insensitivity cases assert.

## Canary

The shape check disabled in place: the witness fails `Expected: <0> / Actual: <10>` with its own
reason. The control and both origin guards pass in that state.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package: 229
passed.

## Not fixed

**The bounded drain now applies to every server, not only gated ones.** A non-upgrade request is
the only kind that carries a body, and rejecting it here means draining it here — up to
`_refusalDrainBudget`, `unawaited`, counted by nothing. The bound is the same one the gated path
already had and the deadline test covers it, but the surface is wider than before and the doc now
says so. Nothing measured how many such holds a server will take.

**Not measured at a load balancer's rate.** Ten requests give the per-request cost; "noise
proportional to probe rate" is arithmetic on top.

**The origin pre-normalisation is unmeasured.** It removes a string allocation per configured
origin per handshake, and that is reasoning, not a number.

## Links

Lens RPC-22. Bench P-165 (new). Lead B-136 closed. The two tests that caught the wrong first
attempts are `origin_guard_test.dart` and `a_refused_upgrade_has_a_deadline_test.dart` — both
earlier rounds' work, doing exactly what they were built for.
