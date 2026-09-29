---
status: open
round: 539 (ownership measured and fixed; the in-flight logging claim untouched)
commit: 11baa648
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: P-172
reason: "cost — the ownership half is CONFIRMED and FIXED; what remains is the lead's third claim, that in-flight calls each log an error during an orderly close, which nothing has measured"
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

## Still open — the lead's third claim

"In-flight calls each log an error during an orderly close." Nothing here measured how a close is
reported to calls that were running; `_closedDuringCall` already exists for it, and whether it logs at
error per call is unasked.

## Owner decision

—
