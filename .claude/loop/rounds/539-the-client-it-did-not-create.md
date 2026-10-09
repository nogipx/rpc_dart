---
round: 539
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-04
bench: P-172 — new
commit: yes
release: breaking
severity: S2
---

# Round 539 — the client it did not create

## Target

B-143: the HTTP/1.1 caller closes an `http.Client` it did not create.

Lens RPC-04 — a capability the caller supplies and the wrapper then mishandles. Here the injected
object is a resource rather than a capability, and the mishandling is disposal: the constructor accepts
one, the doc explains how to configure it, and nothing says who closes it.

## Hypothesis

`close()` calls `_httpClient.close()` even when the client was passed in.

## Before

Arm one read `BROKEN: ClientException` — an injected client answered "Client is already closed" on its
next request.

Bench `../probes/P-172-who-owns-the-http-client.md`.

CONFIRMED. **Read by USING the client, not by observing the call.** Whether `close()` runs is the right
question for one kind of client and the wrong one for the other, so the reading has to be the
consequence.

## Mechanism

`_httpClient = httpClient ?? http.Client()` erases the distinction the moment it is made. Nothing
downstream can tell an injected client from an owned one.

## After

```
  WITNESS an INJECTED client after transport.close()
    usable (204)

  CONTROL a client the transport OWNS must still be closed
    fds 2 -> 4 during the call -> 3 after close
```

`_ownsHttpClient = httpClient == null`, recorded at construction, and `close()` closes only what it
owns. The constructor doc now states the rule.

## Canary

The ownership check removed: the witness fails with the real message,
`ClientException: HTTP request failed. Client is already closed.` The control passes in that state —
which is the point of having it: "stop closing the client" satisfies the witness and leaks on every
transport that made its own.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. rpc_dart_http: 172 passed.

## Not fixed

**The third claim in the lead is untouched**: "in-flight calls each log an error during an orderly
close." Nothing here measured how a close is reported to calls that were running, and it is a separate
question from ownership — `_closedDuringCall` already exists for it.

**The descriptor count does not prove attribution.** It says the resource is gone after the close, not
which layer released it; dart:io could release a finished exchange's connection on its own.

**A CHANGELOG line is owed.** A caller who relied on `transport.close()` disposing of a client they
passed in now has to close it themselves — a leak for that code, where before it was a break for
everyone sharing the client. The new behaviour is the conventional one, but it is a change.

**No sibling has this shape.** The responder transport and the isolate and websocket transports take no
injected client, so RPC-04's parity question has no other instance here.

## Links

Lens RPC-04. Bench P-172 (new). Lead B-143 closed.
