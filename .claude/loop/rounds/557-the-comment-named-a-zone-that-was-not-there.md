---
round: 557
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-13
bench: P-182 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
severity: S3
---

# Round 557 — the comment named a zone that was not there

## Target

B-178, from the external-audit intake, `round: — (not re-measured)`. Two claims: `_discardConnection`'s
doc says it runs inside `runZonedGuarded` while the body is a plain try/catch, and the future
`connection.terminate()` returns is dropped — so "a potential process kill on reconnect".

Chosen over the floors-and-pubspec kind because its failure, if real, bites the owner's own
deployment rather than a third-party consumer: an unhandled async error kills the isolate. That is
the grading question round 556 left open, applied.

Lens RPC-13: an unhandled async error, which on this project has killed a server before.

## Hypothesis

From the lead: `terminate()` on an abandoned connection can complete with an error, nobody handles
it, and it reaches the root zone.

## Before

```
/// Runs inside [runZonedGuarded] rather than behind a `catchError`. Finishing
/// a connection whose socket is already gone makes package:http2 throw
/// `Bad state: Cannot add event after closing` ... Observed exactly that while
/// building this path.
void _discardConnection(http2.ClientTransportConnection connection) {
  try {
    connection.terminate();
  } catch (e) { ... }
}
```

No zone anywhere in the method, and `TransportConnection.terminate` is declared
`Future terminate([int?, String?])` — confirmed in package:http2 3.1.0 — so there is a real dropped
future to worry about.

## Mechanism

The severity claim is **REFUTED**, and the prose claim is **CONFIRMED and fixed**.

The comment's reason is true but belongs to a different call. `finish()` throws
`Bad state: Cannot add event after closing` after its own future has completed, which no call-site
handler can see — round 347 established that and `finish_throws_into_the_zone_test` records it.
`_discardConnection` does not call `finish()`. Its comment was written for that behaviour and
attached to the method that avoids it, where it reads as a warning about the line below it.

So the fix is the comment: say that `terminate()` and never `finish()` is the point, name what
`finish()` would do, and name the test that holds both halves.

## After

```
  CONTROL healthy, future discarded            nothing escaped
  CONTROL healthy, future awaited              nothing escaped
  socket destroyed, future DISCARDED           nothing escaped
  socket destroyed, future AWAITED in try      nothing escaped
  POSITIVE CONTROL finish() on a live socket   ZONE: Bad state: Cannot add event after closing
  POSITIVE CONTROL finish() then terminate()   ZONE: Bad state: Cannot add event after closing
```

Bench `../probes/P-182-where-terminate-s-error-lands.md`.

**Dropping `terminate()`'s future costs nothing observable at either state the method can be in.**
No process kill, and `.catchError` would have nothing to catch — the lead's fix sketch would have
added a handler for an error that does not arrive.

The two `terminate()` rows are now in `finish_throws_into_the_zone_test` beside the `finish()` one,
which is where this knowledge belongs: that file exists because round 347 spent a round getting the
same distinction wrong, and its header says the next reader should not have to.

## Canary

**None, and none is possible for the change made** — the change is a comment, and prose cannot be
switched off.

What stands in for one is the probe's POSITIVE CONTROL, and it is load-bearing rather than
decorative: four silent rows mean "terminate is safe" or "this rig cannot produce the condition",
and only a call known to escape separates them. The first version of the probe had no working
control — a bare TCP listener as the peer, against which `finish()` never completed at all — and
would have reported the same four clean rows with nothing behind them.

The new test arms carry that control with them: they sit in the same file as the `finish()` arm, so
a future reader cannot read the silence alone.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

`analyze` failed once on the way: `unawaited_futures` on the deliberately-dropped
`conn.terminate()` inside an async test closure. Annotated `unawaited(...)`, with the comment
stating that this attaches nothing and so preserves the drop — the shipped call site is synchronous
and needs no annotation. Marking it any other way would have silently fixed the thing under test.

## Not fixed

**`_discardConnection` was not driven through `reconnect()`.** The arms call `terminate()` at the
http2 layer in the two states the method can be in, which is the mechanism; a reconnect against a
half-dead connection would also exercise the surrounding single-flight logic, and that is a
different question.

**package:http2 2.3.1 is unmeasured.** The workspace resolves it for some packages, and `finish()`'s
behaviour already changed once across versions (B-53), so "terminate is silent" is a statement about
3.1.0.

**The lead's `paths:` named one file and one call site.** Whether other `terminate()` or `finish()`
calls in this transport drop futures was not swept; this round answered the site the lead named.

## Links

Lead `../backlog/B-178-http2-discard-connection-lets-an-error-reach-the-zone.md` — CLOSED:
severity refuted, prose fixed.
Bench `../probes/P-182-where-terminate-s-error-lands.md` — new.
Round `556-no-published-core-satisfies-any-floor.md` — whose open grading question picked this lead.
Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [557]`.
