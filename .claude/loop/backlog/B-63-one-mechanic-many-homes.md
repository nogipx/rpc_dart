---
status: closed (round 422)
round: 422
commit: 406f6536
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http/lib/**]
probe: none — READ, not measured
reason: cost — six mechanics with no shared owner across core and the transports; two fail SILENTLY when the thing they depend on moves, and three have already drifted
---

# B-63 — one mechanic, many homes

**Six of them, ranked by what a drift COSTS rather than by how much code
repeats.** The top two fail silently; the rest have already drifted at least
once.

```
  #  mechanic                 homes  drift evidence
  5  'Transport is closed'     11    matched by string literal across 4
                                     packages; two files document the coupling
                                     in COMMENTS
  2  _inFlightCalls()           2    stringly-typed map key; a rename makes
                                     every drain complete instantly
  1  _ensureUsable              2    ALREADY stale in both copies (round 414)
  6  wireStatusFor -> sendError 4    one copy already repaired for being the
                                     odd one out
  4  _startKeepalive            2    already drifted by an _isClosed check
  3  _notify                    2    not drifted; guards process death
```

Asked for by the owner after [B-56](B-56-five-copies-of-one-subscription-discipline.md)
was ranked first: sweep the project for the general case, not only the
subscription discipline — **anything that could be one thing the others use.**

**READ, not measured.** Nothing below has a witness.

## The bar, which most duplication does not clear

RPC-25 declines cosmetic unification, and the owner's qualifier on RPC-08 says a
code-shape difference is a LEAD, not a defect. So similarity alone is not the
finding. What makes a copy worth an owner is one of:

- it has **already drifted**, or
- it fails **silently** when the thing it depends on moves.

Each of the four below has one of those. Everything else the sweep turned up is
in "Already extracted" and should not be re-filed.

## 1. `_ensureUsable` — and it has ALREADY produced a stale claim, twice

`rpc_http2_caller_transport.dart:195` and `websocket_caller_transport.dart:77`.
Same guard, same type, same status code, messages differing by one word
("connection" / "socket"). Both carry a long comment explaining WHY the code is
`FAILED_PRECONDITION` and not `UNAVAILABLE`, and both say the same thing:

> NOT UNAVAILABLE — `RpcRetryInterceptor` retries that and **never calls
> `reconnect()`**, so the retries spin against the same dead connection.

**That is no longer true.** Round 414 closed B-61 by teaching the interceptor to
reconnect: `retry_interceptor.dart` now calls `_reconnectIfConnectionIsGone`
after the backoff, for UNAVAILABLE exactly. One fact, two homes, and the round
that changed the fact updated neither.

This is the whole argument for the lead, arriving on its own within a few rounds
of the duplication being written. The decision may still be right — it is the
JUSTIFICATION that rotted — and a round taking this has to re-derive whether
`FAILED_PRECONDITION` is still the correct code now that UNAVAILABLE reconnects,
rather than transcribing the comment into a shared home.

## 2. `_inFlightCalls()` — identical, and it fails SILENTLY

`rpc_http2_server.dart:269` and `rpc_websocket_server.dart:236`, byte for byte:

```dart
int _inFlightCalls() {
  var total = 0;
  for (final endpoint in _endpoints) {
    final metrics = endpoint.collectEndpointMetrics();
    total += (metrics['activeResponders'] as int?) ?? 0;
  }
  return total;
}
```

The count comes out of a **stringly-typed map**. Rename or drop
`'activeResponders'` in `responder_pipeline.dart:576` and both copies return 0
— not an error, not a warning: **"nothing in flight", so every graceful drain
completes instantly** and a rolling deploy silently stops draining. The `as int?`
and the `?? 0` are what convert the mistake into a plausible answer.

This is the worst shape in the list, because the failure looks like success.

## 3. `_notify` — two copies of a process-death guard

`rpc_http2_server.dart:367` and `rpc_websocket_server.dart:270`, byte for byte.
It exists because both servers invoke user callbacks on DETACHED paths, where a
throw reaches the root zone and kills the isolate. `rpc_dart_http` has no copy
and needs none — it has no connection callbacks.

Not drifted yet. It is here because of what it guards: a class where the
consequence of one copy falling behind is process death, not a wrong value.

## 4. `_startKeepalive` — already drifted by one check

`rpc_http2_caller_transport.dart:266` and `rpc_http2_server.dart:286`, in the
same package. Both are `Timer.periodic` + an `inFlight` re-entrancy flag +
`ping().timeout(timeout)` + `timer.cancel()` on failure + `finally { inFlight =
false }`, and the re-entrancy comment is almost word for word the same in both.

**The caller also checks `_isClosed` inside the tick and cancels the timer; the
server does not.** Whether that matters depends on whether the server's timer is
always cancelled elsewhere — unverified, and the round that takes this must
check rather than assume, because that asymmetry is either a gap or a fact worth
writing down once.

The endings legitimately differ (caller: `_disconnected = true` +
`_discardConnection`; server: `_notify` + `socket.destroy()`), which is what a
shared helper would take as a callback rather than flatten.

## 5. `'Transport is closed'` — a cross-package protocol made of a string literal

**The largest of the six, and the one with the most homes.** The owner scoped a
second sweep to core+transports; this is what it found.

The literal appears in **eleven production sites across six files and four
packages**, and is consumed by LITERAL STRING COMPARISON:

```
PRODUCERS (11)
  caller_pipeline.dart:322                      StateError
  channel_transport.dart:437                    RpcStatusException(unavailable)
  channel_transport.dart:608                    message: field
  rpc_http2_caller_transport.dart:196           StateError
  rpc_http2_responder_transport.dart:748,845,899  StateError x3
  rpc_http_caller_transport.dart:274,290,311    StateError x3
  websocket_caller_transport.dart:78            StateError

CONSUMER (1)
  base_processor.dart:18,23   _isTransportClosed(), matching BOTH spellings
                              by `error.message == 'Transport is closed'`
```

Change the wording at any one producer — a typo, a capital, a trailing period,
one transport made more descriptive — and `_isTransportClosed` returns false for
that transport alone. Its four call sites (`base_processor.dart:404, 439, 771,
1702`) use it to SKIP reporting a failure nobody can receive, so a missed match
turns an ordinary shutdown into a logged error, per transport, with nothing
catching it. Same silent shape as `_inFlightCalls`, four times the surface.

**The code already admits the fragility in a comment instead of fixing it**:
`rpc_http_caller_transport.dart:579` explains it throws
*"`StateError('Transport is closed')`, matching every sibling"*, and
`channel_transport.dart:430` documents its own spelling by pointing at a
PRIVATE function in another library. Two files describing a contract that has
no declaration.

The extraction is small and the shape is already in the repo: a named constant,
or better a predicate beside the thing that throws, so producers and consumer
cannot disagree. `_isTransportClosed` being private to `base_processor.dart` is
what forced the comment-based coupling.

## 6. `wireStatusFor` → `sendError`, written out four times

The "a handler threw, tell the peer" idiom, once per responder shape:

```
client/responder.dart:143          try { await _processor.sendError(...) }
                                   catch { log }
server/responder.dart:219, 259     bare await, then _completeDone()
bidirectional/responder.dart:169   unawaited(...).catchError((_) {}),
                                   behind a `finished` flag
unary/responder.dart:212           does NOT use _processor.sendError -- builds
                                   the trailer by hand over _streamStates
```

Each is `final wire = wireStatusFor(error);` followed by the same three fields
(`wire.status`, `wire.message`, `wire.detailsBin`). Add a field to the wire
status and four sites must learn it.

**Drift is already on the record, in the code's own words.**
`unary/responder.dart` carries: *"The three streaming shapes route this through
StreamProcessor's request controller and the zero-copy unary branch calls
sendError directly; this one did neither"* — one of the four had to be repaired
because it was the odd one out.

**Checked and NOT a defect**, so nobody re-derives it: the trailer trimming
agrees everywhere. `StreamProcessor.sendError` applies
`maxHeaderValueBytes` (`base_processor.dart:761`) and unary's hand-built path
applies it too (`_policyOf(_transport).maxHeaderValueBytes`). The four differ
only in how hard they guard a call that already swallows its own failures, which
is weaker than it looks.

## Already extracted — do NOT re-file these

The sweep's negatives, and they matter: this project has applied the pattern
before, so these are the boundary rather than candidates.

```
drainUntilIdle        the drain POLLING LOOP is already shared by all three
                      servers -- http2, websocket and http each call it
BackoffPolicy /       shared; client_connection and retry_interceptor both
  ExponentialBackoff  take it as a policy object
wireStatusFor         shared; rounds 412-413 made it the single default-deny
                      route from an error to a wire status
metadata validation   shared via RpcChannelTransport's outbound policy check;
                      http2 and http were brought onto it (B-34, round 340)
RpcMessageParser      shared in core/parser.dart; base_processor and BOTH http2
                      transports construct it rather than re-framing
per-stream bookkeeping  NOT duplication. The websocket responder transport is
                      101 lines because the channel transports ride
                      RpcChannelTransport; http2's 37 map references are its own
                      because it maps onto package:http2's streams. One shared
                      implementation plus one protocol-specific one is RPC-10's
                      correct shape, not a copy
```

`drainUntilIdle` is the direct precedent for #2: the loop was extracted and the
COUNT that feeds it was not. The same asymmetry runs through #5 — the shared
layer exists, and the STRING the layers agree on does not.

## Scope of the sweep, stated so it is not over-read

**Second pass scoped by the owner to core and transports.** Covered: the three
servers, all caller and responder transports, the four call shapes on both
sides, `base_processor`, the channel transports, and core's resilience,
endpoint and contract layers.

**Not covered, deliberately**: `packages/data`, `packages/notify` and
`packages/blob` are outside the scope the owner set for this sweep, and B-10
still defers LOOKING there. The wasm plugin's Swift and Kotlin halves are a
transport package but a different language pair, and reading them is its own
job. Neither absence should be read as "clean".

**One finding was dropped by the narrowing and is recorded here so it is not
lost**: there are TEN implementations of three interchangeable interfaces
(`IBlobRepository` 4, `IDataStorageAdapter` 3, `INotifyRepository` 3) and **no
shared conformance suite anywhere** — each package tests its own adapter in 2-5
ad-hoc files. That is the extraction that would have caught B-33 automatically,
and it sits outside core+transports.

## Owner decision

—

## The largest item closed — round 416

**`'Transport is closed'` is no longer a message.** `RpcClosedException` is a
type carrying FAILED_PRECONDITION and a `what` field, and `_isTransportClosed`
is one `is` check. The eleven production sites across four packages now throw
it, and so do the five `'Endpoint is closed'` guards.

The lead predicted this would fail silently when the wording moved. It had
ALREADY failed: `channel_transport.dart:437` threw
`RpcStatusException(unavailable, 'Transport is closed')` while ten siblings
threw `StateError`, so `_isTransportClosed` had been widened to accept both
spellings rather than the drift being removed. An ordinary shutdown on that one
transport logged as a real failure until the matcher was patched.

**Item (1) is closed too.** Both `_ensureUsable` copies justified
FAILED_PRECONDITION with *"`RpcRetryInterceptor` retries that and never calls
`reconnect()`"* — which round 414 made false. The status is unchanged and still
right; the reasoning is rewritten to the one that survives: this is a LOCAL
refusal that names its own remedy, so the caller applies the remedy instead of
retrying into it.

## The remaining four — round 422; the lead is closed

**`_inFlightCalls` was the one with teeth, and this session had made it worse.**
It is now `RpcEndpointBase.activeResponderCount` — TYPED, so the compiler checks
it — with `inFlightResponderCalls` in core beside `drainUntilIdle`, and the
metrics key reading FROM it. The canary is the whole finding: renaming the key
to `liveResponders` fails the test that watches the coupling and **leaves the
websocket drain passing**, where before it would have zeroed the drain silently
with every test green.

`_notify` → `notifyWithoutDying`, `wireStatusFor` → `sendError` → `sendWireError`
at four responder sites.

**`_startKeepalive` is HALF-extracted, and that is the answer rather than a
shortcut.** Shared: the loop, the latch, and the `isDead` guard the server half
lacked. Not shared: the response, because the two differ on purpose — the caller
marks itself disconnected so a supervisor reconnects; the server destroys the
socket so the release wiring disposes the contracts. Forcing those together is
the cosmetic unification this lens declines. The server's missing guard is also
narrower than this record implies: `socket.done` already cancelled the timer, so
the window was "a stopped server whose socket is still open".
