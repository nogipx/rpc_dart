---
round: 537
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: P-170 — new
commit: yes
severity: S3
---

# Round 537 — the drain that always threw

## Target

B-141: the body-read timeout does not stop the read, and `_reject`'s drain always fails.

Lens RPC-15 — re-measure your own record. The first half is a question `checked/C-31` answered in
round 273, and the lead reopens it, so it was re-run rather than cited.

## Hypothesis

`readBody().timeout()` abandons the future while the read keeps running; and `_reject` then calls
`request.read()` a second time, shelf throws, and `catch (_)` swallows it.

## Before

```
  half two — a second read() on one shelf Request
    StateError: The 'read' method can only be called once on a shelf.Request/shelf.Response object.

  half one — a slow body, 4 MB promised and 5 bytes sent
    arm                     the peer saw                  wrote after (KiB)
    bodyReadTimeout 500ms   HTTP/1.1 408 Request Time-out 384
    CONTROL no timeout      NOTHING within 6s             4096
```

Bench `../probes/P-170-does-the-rejection-drain-run-at-all.md`.

**First half REFUTED again, and C-31 reproduced exactly** — the same 384 KiB of socket buffer, at
today's sha, against a control that takes 4096 KiB and answers nothing. The read does stop.

**Second half CONFIRMED as a fact**: the drain throws `StateError` on the 408/413/400 paths, because
the body reader has already consumed the request.

**And it is HARMLESS**: the peer still gets its 408. C-31's explanation is why — the body is still
attached when the response completes and dart:io detaches it then.

## Mechanism

`_handleRequest` calls `_reject` from seven places. Four run before the body reader; three run from the
catch that maps `TimeoutException` to 408, `_BodyTooLarge` to 413, and anything else to 400. Those
three reject a request whose body has been read, so the drain's `request.read()` raises immediately —
into a `catch (_)` whose comment says it is there for a peer that has gone away.

## After

`_reject` takes `drainBody`, and the three post-read callers pass false. The catch narrows: a
`StateError` is now logged at warning, because every other failure there is the peer's doing and that
one can only be ours.

**Behaviour is unchanged** — the 408 still arrives, the pre-read drain still runs. What changed is that
the transport no longer performs an operation it knows will fail, and no longer hides the error when it
does.

## Canary

`drainBody: true` restored on the post-read path: the witness fails `Expected: <0> / Actual: <1>` with
its own reason. The control passes.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. rpc_dart_http: 167 passed.

## Not fixed

**Two rig errors, both worth keeping.**

The probe's first version used a hand-written stand-in server instead of the transport, and reported
`closed with nothing` where the real thing reports `408` — the two differ in exactly the detail under
test. A stand-in for the code under test measures its author.

The witness's control first asserted that a pre-read 415 reaches a SLOW-body peer. It does not, and
deliberately: the pre-read drain is deadlined, so a body that never arrives is answered by a teardown
rather than a status — which is what `a_refused_request_has_a_deadline_too_test` pins. Asserting a
status there asks for the thing the deadline gives up. Rewritten with a complete body, which is the
case the drain exists to serve.

**A third rig error caught by the control**: counting every warning counted the 415's own log line. The
counter now matches the drain's message, which is the only record the round is about.

**`close()`'s drain is untouched.** The lead names it in the same sentence and nothing here looked.

**No CHANGELOG line is owed.** Nothing observable to a peer changed; the new warning fires only where a
programming error already existed.

## Links

Lens RPC-15. Bench P-170 (new). Lead B-141 closed. `checked/C-31` is the record this re-measured and
confirmed; `a_refused_request_has_a_deadline_too_test.dart` (round 272) is what makes the slow-body
teardown correct rather than a defect.
