---
round: 366
commit: bb8548939524ee67a53dcc5339d15f772e3f032e
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
scope: [rpc_dart]
---

# C-38 — the lenient send after close does not cost a client-stream a message

`RpcChannelTransport.sendMessage` / `sendMetadata` / `sendDirectObject` open
with `if (_closed) return;`, and `sendMessage` repeats it after parking for
flow-control credit. Five siblings do the opposite —
`rpc_dart_http` (3 sites), `rpc_dart_http2` (4), `RpcWebSocketCallerTransport`
and `RpcCallerPipeline` all throw `StateError('Transport is closed')`, and
`_isTransportClosed` in the stream processors matches that exact message. This
transport is the only lenient one, and it is the one under websocket, isolate
and wasm.

The hypothesis was that this is how a consumer's blob upload comes back
**acknowledged short**: a client-stream whose caller is told each send went out
while nothing reached the wire, and a peer that answers normally for the
messages it did get.

## Measured — it is not

```
CONTROL        send returned, peer received 1 message(s)
CLOSED-FIRST   send returned normally; peer received 0 message(s)
CLIENT-STREAM  failed: RpcStatusException(14): Stream closed before the server
                       completed the call
```

The send is indeed silent (CLOSED-FIRST). **The call is not.** Four messages
sent across a close, two of them after it: the caller never gets a short answer,
because the response arrives on the READ side of the same dead transport and the
call fails UNAVAILABLE. For the field symptom to appear, messages have to go
missing while the connection stays usable — which a closed transport is not.

## The fix that was written and reverted

`_refuseIfClosed()` on the three send methods, raising the siblings' exact
message. It works (`CLOSED-FIRST send threw StateError: Transport is closed`)
and it costs four tests, one of which is a GUARD named
*"the documented leniency after close is unchanged"*:
`closed_transport_call_test.dart` pins `returnsNormally` for exactly these
calls, its header explains that the throwing version was deliberately NOT taken,
and the transport's own docs say "use after close fails cleanly (no throw, no
delivery)". The change also turned the caller's error from
`RpcStatusException(14)` — retryable, which is what a consumer's upload retry
keys on — into a bare `StateError`, which is not.

So it is a contract change, it makes the retryable case unretryable, and the
defect it was aimed at is elsewhere. Reverted; the transport is untouched.

**If it is ever taken up anyway** (the asymmetry is real, and "five throw, one
returns" is a drift someone will find again): raise
`RpcStatusException(RpcStatus.unavailable, 'Transport is closed')` rather than
`StateError`, widen `_isTransportClosed` to match it, and rewrite the guard
rather than deleting it.

## It WAS taken up — noted in round 367

`2ec53853 fix(rpc_dart)!: a send that does not send must not report success`
did exactly that, by the recipe above: `_refuseIfClosed()` now guards the three
send methods and raises `RpcStatusException(RpcStatus.unavailable)`, and
`_isTransportClosed` accepts both spellings. So the paragraph "Reverted; the
transport is untouched" describes a tree that no longer exists.

What this negative still establishes is the part that did not change: **the
lenient send was not the consumer's lost message.** That measurement stands on
its own and is why B-44 eliminated this candidate.

## Control

`CONTROL` is the row: the same call on a transport that was NOT closed first,
which returns and delivers one message to the peer. Against it, `CLOSED-FIRST`
returns identically while the peer receives nothing — so the probe can
distinguish a silent send from a working one, and the silence is real.

The row that decides the negative is `CLIENT-STREAM`, and its control is the
same: four messages across a close, two after it. A short answer would have
shown as a peer completing normally on two messages. It did not — the call
failed `RpcStatusException(14)`, because the response travels the read side of
the same dead transport. That is the outcome the field symptom requires and does
not produce.
