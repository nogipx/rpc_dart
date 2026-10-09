---
round: 561
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none — both items are settled by reading the call's own documented contract, and the one with an observable has a witness in the tree
budget: probes 0/5, canaries 1/5
commit: yes
release: changelog
severity: S3
---

# Round 561 — two comments about one call disagreed

## Target

Two more of B-151's five items, taken because round 560 left the file open and the lead at four
remaining:

- **item 1**: `afterModulesStart` dereferences `_transport!` when `start()` has not run.
- **item 3**: `stop()`'s two comments contradict each other.

Lens RPC-15, in its rule-one form: a comment is a record and ages like one, and a divergence is a
defect fixed in the round that finds it.

## Hypothesis

Item 3 is the interesting one, because the audit gave line numbers that have since moved and I could
not see a contradiction in the current text. Either the audit was wrong, or the contradiction is
between two comments far enough apart that reading the method alone does not show it.

## Before

The audit was right, and the two halves are 25 lines apart — a doc comment above `stop()` and an
inline comment inside it, about the SAME call:

```
/// `HttpServer.close(force: false)` is NOT a drain, which is worth stating
/// because it reads like one: it stops the server listening and completes as
/// soon as the port is released, merely declining to kill active connections.

    // With a drain this ordering does double duty -- `close(force: false)`
    // stops accepting AND waits for what is already running
```

One says the call does not wait; the other says it waits. `dart:io` settles it — `close()` completes
when the port is released, and only `force: true` touches active connections — so **the doc comment
is right and the inline one is false**.

And item 1, read off the line:

```
final transport = _transport!;   ->  Null check operator used on a null value
```

## Mechanism

**The false comment is the dangerous half, and not because it misinforms.** It offers a REASON for
the ordering — "does double duty" — which, if believed, makes the explicit `_drainRequests` call
below it look redundant. The next person tidying this method deletes the only thing that actually
waits, and the `stop()` doc three lines up explains exactly what then happens: the endpoint is closed
under live handlers and the caller hangs with no answer ever coming.

So the inline comment now says what `close(force: false)` does, says the drain is what waits, and
says not to remove it. What the ordering really buys is stated separately: the endpoint stays alive
while the drain runs.

Item 1 is an ordering contract, so a violation should read like one. `_transport!` is replaced by a
named local and a `StateError` that names both phases and mentions that a `stop()` clears the
transport too. **The throw happens BEFORE the bind claim is set**, so a corrected caller can simply
call the two in order.

## After

```
WITNESS phase two without phase one NAMES the mistake      StateError naming both phases
  ... and the ordinary sequence still works afterwards      isRunning=true
CONTROL one phase-two serves calls                          ok:x
WITNESS two concurrent phase-twos still serve calls         ok:x   (round 560)
```

## Canary

```
the bare dereference restored (`_transport!`)

WITNESS phase two without phase one NAMES the mistake
  Expected: throws <StateError> with `message`: (contains 'start()' and
            contains 'afterModulesStart()')
    Actual: threw _TypeError:<Null check operator used on a null value>
            stack rpc_dart_http/src/rpc_http_server.dart 186:33
```

**Item 3 has no canary and cannot have one** — it is prose, and the round says so rather than
inventing an arm. What stands behind it is the call's documented contract plus the `stop()` doc
comment that already said the right thing, which is the same evidence that settles which half was
false.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

## Not fixed

**Two of B-151's items remain and both need a rig.**

Item 2 — `close(force: true)` destroying connections before the promised 503 — is the one with a real
consequence, and reading the method is not enough to place it: the force close is the documented cut
after the budget expires (*"anything still going when the budget expires is cut here"*), so the claim
is about which promise the transport makes to a request that arrives DURING the drain, not about the
close itself. That needs a request in flight at the moment the budget runs out, and an observation of
what the peer receives — a reset or a 503.

Item 4 — the drain polling `health().details['pendingRequests']` every 25 ms — is a design change: a
typed pending count on the transport, replacing a string-keyed lookup through a diagnostic. No
failure to measure, and `drain.dart` already criticises the pattern, so it is cost and shape rather
than behaviour.

**A CHANGELOG line is owed for item 1**: calling `afterModulesStart()` before `start()` now throws
`StateError` instead of a `TypeError`. Both are bugs in the caller; only one says so.

## Links

Lead `../backlog/B-151-http1-server-lifecycle-defects.md` — three of five items done, two left with
what each needs.
Round `560-the-guard-was-behind-the-await.md` — item one, in two packages.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [561]`.
