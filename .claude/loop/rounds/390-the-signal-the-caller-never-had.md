---
round: 390
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-79 — reused
commit: yes
---

# Round 390 — the signal the caller never had

## Target

B-54, at the owner's direction — the last of the three defects from their audit,
and the last round before the cap. Round 386 measured it and refuted both cheap
fixes; what was left was a surface change, which is exactly the thing not to
start near a cap unless it fits in one round. It fits: the signal already
existed, it was simply not exposed.

RPC-25 for the sixth round running.

## Hypothesis

The caller can be told its call has ended, by the same event every ending
already produces, and stopping the producer on it costs nothing else.

## Before

P-79's third arm, unchanged:

```
the producer after the call has ended
  produced 11 when the call ended, 32 a quarter-second on
```

The server answers once and finishes; the producer runs to the end of its
source, each message failing into the same logged error. An endless producer —
a chat, a sensor feed — is an endless error log.

## Mechanism

Round 386 refuted the two obvious signals: `send()` does not throw (C-35), and
`isActive` stays TRUE after a server-ended call. What none of them noticed is
that **every ending closes `_responseController`** — END_STREAM, a non-OK
trailer, a deadline, cancellation, the scope's disposal, all eighteen sites.
That controller's own `done` future is therefore the signal, and it was already
there; nothing exposed it.

`CallProcessor` now has `Future<void> get done => _responseController.done`, and
`requestSink` cancels its subscription on it. `ClientStreamCaller.call(Stream)`
has raced its request stream against the response with `Future.any` all along —
the sibling again, and the reason its copy never had this defect.

## After

```
the producer after the call has ended
  produced 2 when the call ended, 2 a quarter-second on
```

The other two arms of P-79 are unchanged: `close()` still does not throw, and
the onError path still reaches no zone.

## Canary

`if (1 > 0) return;` at the top of the `done` handler:

```
WITNESS: the producer stops once the call has ended
  Expected: <13>
    Actual: <39>
  the producer kept running after the call ended (was 13, now 39)
```

The witness carries a second assertion that makes the first mean something —
`atEnd` must be below the source's own limit, or a source that simply drained
in time would pass while proving nothing. And the three tests already in that
file — close during an addStream, the zone-free error path, close with nothing
running — stayed green throughout.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 15 packages**,
rpc_dart **+1562 ~1**.

**One red, recorded rather than buried.** The first workspace run showed
`rpc_dart_isolate +77 -1`. It did not reproduce: the package passes alone
(`+78`), passes in a four-package concurrent run, and passes in a second full
workspace run. The isolate package is untouched by this round, and the failure
arrived with no captured message. Filed here as the load-shaped red `config.md`
warns about — named, not called a flake without the check (L-14).

## Not fixed

**B-53's narrow half**, where the stream was never half-closed and rpc_dart's
own RST_STREAM is the only signal. Unchanged from round 388; it needs something
`package:http2` does not expose.

`payloadResponses`' unreachable grpc-status branch, recorded in B-55 — cosmetic,
and deleting it wants a test pinning `_grpcStatusErrorTransformer` first.

## Links

- RPC-25 — the lens; `applied:` gains 390. Sixth round running, and the sibling
  (`ClientStreamCaller`) was the model for the third time
- P-79 — reused unchanged, which is what let the third arm be the only variable
- B-54 — closed by this round; the owner's three are now all fixed
- C-35 — why the send-failure signal is dead; round 386 — where both were refuted
- L-14 — a red that reads like a known flake, and what it takes to call it one
