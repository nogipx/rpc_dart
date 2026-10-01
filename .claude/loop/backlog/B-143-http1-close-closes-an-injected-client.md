---
status: closed (round 587)
round: 587 (539 measured and fixed the ownership half; 587 the logging one)
commit: 11baa648
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: P-172, P-207
reason: "both halves CONFIRMED and FIXED. 539: an injected client answered `Client is already closed` and now reads `usable (204)`. 587: an orderly close logged one error PER in-flight call, 8/1/0 against the call count, now 0 with the event recorded at `internal` instead"
---

# B-143 — HTTP/1.1 caller closes an `http.Client` it did not create

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`close()` calls `_httpClient.close()` even when the client was passed in; ownership is not documented; in-flight calls each log an error during an orderly close.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:154, 498, 602`.

## Why it matters

A shared client breaks for every other user.

## What round 539 measured

Before: an injected client answered `BROKEN: ClientException` — "Client is already closed" — on its next
request. After:

```
  WITNESS an INJECTED client after transport.close()
    usable (204)

  CONTROL a client the transport OWNS must still be closed
    fds 2 -> 4 during the call -> 3 after close
```

Bench `../probes/P-172-who-owns-the-http-client.md`. **Read by USING the client**, not by observing
whether `close()` ran — that is the right question for one kind of client and the wrong one for the
other.

## Fix

The sketch, made concrete: `_ownsHttpClient = httpClient == null` recorded at construction, since
`httpClient ?? http.Client()` erases the distinction the moment it is made. The constructor doc now
states the rule.

The control is what stops this being a trade: "do not close the client" satisfies the witness and leaks
on every transport that made its own.

**A CHANGELOG line is owed**: a caller who relied on `transport.close()` disposing of their client now
has to close it themselves.

## The third claim — measured in round 587, CONFIRMED and fixed

"In-flight calls each log an error during an orderly close." "Each" is the claim, so
the arm has to SCALE — one record would be a message:

```
8 calls in flight   errors before 0   errors after 8
1 call  in flight   errors before 0   errors after 1
0 calls             errors before 0   errors after 0
```

`close()` closes the client it owns, every parked request fails with a
`ClientException`, and the generic catch at `_fireRequest`'s end logged at `error`.
The 0-call arm says the records come from the calls and not from `close()` itself.

**The sibling is the next branch down in the same `try`.** `http.RequestAbortedException`
is already logged at `internal`, with the reason written out: *"logging it at error
would make every ordinary cancellation look like a failure"*. A close is the same
event with a different trigger, and `close()` sets `_isClosed` before closing the
client, so the flag is a reliable signal by the time each request lands.

After: `errors 0, internal 16` for eight calls. The event is still recorded, one
level down — which is why the probe admits `internal`: with the default level a
count of zero errors cannot be told from a log that was deleted. The status a
consumer sees is untouched; it comes from `_closedDuringCall` by way of `closeAll`.

Not covered: the responder half of this package has its own close path, and no arm
reads the consumer side beyond the suite's GUARD that a real failure with the
transport OPEN still logs at `error`. `P-207`.

## Owner decision

—
