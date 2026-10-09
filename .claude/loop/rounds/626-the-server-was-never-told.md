---
round: 626
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-12
bench: none — the witness counts the server's live handlers directly
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 626 — the server was never told

## Target

B-232, from the audit of 2026-10-02: a server-stream call that ends on the
caller side for a reason the server cannot see.

## Hypothesis

`ServerStreamCaller.call()` closes only its local scope. The server learns of a
caller-side ending only through the cancellation token, which the endpoint fires
on a consumer cancel and on nothing else.

## Before

```
maxConcurrentHandlers 2, two server streams, each fails on its 2nd response
  response the caller cannot decode     activeResponders 2 after 5 s
  caller response middleware throws     activeResponders 2 after 5 s
control: the consumer leaves            activeResponders 0, next unary served
```

The audit's probe: the handler went on producing (`2 -> 155` in 2 s), and the
next unary on the connection read `status 8`.

## Control

Bidi with the same decode failure tells the peer (`cleanup(abortPeer: true)`),
and client-stream does too (`notifyPeerOfAbort`). Server-stream was the one shape
without it.

## Mechanism

`call()`'s `finally` ran `close()`. Every ending the server did not cause (a
decode error inside the loop, the generator cancelled by a throwing middleware
downstream) left the server's handler running.

## After

`call()` records when the SERVER ended the call (its trailer, an error status,
or the stream completing). Any other way out sends the abort notice before
`close()`, unless the token was already cancelled, which has told the server
itself. All three arms green; activeResponders reaches 0.

## Canary

The before table is the same witness without the notice.

## Gate

`melos run test:unit`: every package green but one test in rpc_dart_websocket,
round 624's handshake witness, which timed out waiting for the client socket to
close. With `cancelOnError: true` a reset arrives as an error and ends the
subscription without `onDone`; the witness waited on `onDone` only. It now
completes on either. analyze, format, license green.

## Not fixed

Not run on dart2js: the notice is sent from the `async*` generator's `finally`,
and the endpoint's bridge does not await the cancel, so a cancel that hangs
there cannot block teardown. `test:web` runs with round 627's gate.

## Links

Lead `../backlog/B-232-a-server-stream-that-fails-locally-never-tells-the-server.md` — closed.
Lens `../lenses/RPC-12-cancel-into-request-stream.md` — `applied: [..., 626]`.
Test `packages/core/rpc_dart/test/endpoint/a_server_stream_that_fails_locally_tells_the_server_test.dart`.
