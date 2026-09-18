---
round: 387
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-18
bench: P-78 — reused
commit: yes
---

# Round 387 — the reset is the trigger, and both easy guards are dead

## Target

B-53, because it is the one thing standing between the owner's goal and a
finished HTTP/2 column. Websocket and isolate are settled (C-44, C-45);
HTTP/2's endings are clean (P-77) and its DUPLEX is not, for one reason: an
ordinary consumer that stops reading one event early costs the whole
connection (P-78).

RPC-18 — the dependency reassembles the wire below every ceiling you set — is
the lens, because round 385 ended by proving the death happens below rpc_dart's
own error paths.

## Hypothesis

The client's RST_STREAM is the trigger, and rpc_dart can decline to send it when
the call is already over.

## Before

P-78 reused unchanged, five mirror calls of 12 messages, pinging after each:

```
link     consumer lets go at   result
direct   the last payload      5 of 5 clean
direct   onDone (the trailer)  5 of 5 clean
50 ms    the last payload      DEAD from call 2   <- the SERVER closed
50 ms    onDone (the trailer)  5 of 5 clean
```

## Mechanism

**The trigger is proven, by ablation.** `stream.terminate()` removed from
`RpcHttp2CallerTransport.resetStream`, everything else identical:

```
link     consumer lets go at   with the reset   without it
50 ms    the last payload      DEAD from 2      5 of 5 clean
```

So the RST_STREAM the cancel becomes is what costs the connection, and nothing
else in the teardown does.

**What it is NOT.** Both obvious rpc_dart-side guards were written and are dead:

- **skip the reset when `_statusReceived` holds the stream** — never fires.
  rpc_dart's view of "the peer finished" is set when IT parses the trailer, and
  in this race the trailer has not been parsed yet. Measured: unchanged, dead
  from call 2.
- the earlier candidate from round 385, the outgoing pump's unhandled
  `addStream` future, was already refuted there.

**And the dependency's two relevant paths say this should be harmless**, which
is why it took an ablation to believe. Read in `http2-2.3.1`:

- `stream_handler.dart:406` `_terminateStream` writes RST_STREAM **only** for a
  stream in `Open`, `HalfClosedLocal`, `HalfClosedRemote` or a Reserved state —
  so terminating an already-closed stream is a no-op;
- `stream_handler.dart:566` an incoming `RstStreamFrame` for a stream that is
  not in `_openStreams` is a connection error **only if it is "idle"**
  (`streamId > lastRemoteStreamId` for a peer-initiated stream), and this one is
  not idle — the comment right there says *"RstFrames for already dead (known as
  'closed') streams should be ignored"*.

Both guards read correct, and the connection still dies. So the remaining gap is
between them: on the CLIENT the stream is still open when the cancel lands (the
trailer is in flight), so the reset really is written; on the SERVER the stream
is closed and the reset is supposed to be ignored. What turns that into a closed
TCP connection is inside `package:http2` and is not visible from either end's
logs — rpc_dart's server logs nothing at warning or above on the arm that dies.

## After

n/a — nothing changed. `git diff --stat` empty before the verdict.

## Canary

n/a — no fix. The ablation IS this round's variation and it is the sharpest form
available: one statement removed, one arm moves from DEAD to clean, the other
three unchanged.

## Gate

No library code moved, so round 386's gate stands.

## Not fixed

**B-53.** What this round adds: the trigger is certain, the two cheap guards are
measured dead, and the dependency's own reasoning is quoted so the next attempt
starts past it.

The fix direction that remains is a TRADE, which is why this stays the owner's:
suppressing the reset for a stream we have already half-closed would fix this
case and break the one cancellation exists for — a client that half-closes
immediately and then abandons a long server-stream download needs that reset to
stop the server. The two are the same wire state (`HalfClosedLocal` plus a
cancel) and rpc_dart cannot tell them apart without knowing whether the peer has
finished, which is the very thing it learns too late.

Two routes that are not trades, for whoever takes it:

1. **Ask `package:http2` for the stream state** before terminating. Its public
   API does not expose it; that is an upstream feature request, and a small one.
2. **Report it upstream** with this round's reproduction, which is now four
   arms and one ablated statement rather than a story.

## Links

- RPC-18 — the lens; `applied:` gains 387
- B-53 — the lead, advanced not closed
- P-78 — reused unchanged, which is what let the ablation be the only variable
- Round 385 — where the trigger was found; round 384 — where the family started
- B-12 — the same address in the same dependency, and the same kind of answer
