---
round: 560
verdict: FIXED
packages: [rpc_dart_http, rpc_dart_http2]
lens: RPC-08
bench: P-184 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
---

# Round 560 — the guard was behind the await

## Target

B-151, taken because its filed consequence is the worst thing on the audit's list that touches the
owner's own deployment — and the highest-severity line in it:
*"crash, total outage (everything 503) after a double start"*. The lead bundles five items; this
round takes the one with a consequence, and the class turned out to span two packages.

Lens RPC-08: one shape, two transports, two different disasters.

## Hypothesis

From the lead: two concurrent starts both pass the guard because the flag is set after an await, and
the loser's catch closes the shared transport.

## Before

```
rpc_dart_http   (afterModulesStart, fixed port)
  CONTROL one call          bound           isRunning=true   endpoints=1  call -> ok:x
  TWO concurrent            bound + threw   isRunning=true   endpoints=0  call -> status 14
  THREE concurrent start()  call -> ok:x

rpc_dart_http2  (start, fixed port)
  CONTROL one start()       started           isRunning=true   call -> ok:x   port free after stop()
  TWO concurrent start()    started + threw   isRunning=false  call -> ok:x   PORT STILL BOUND
```

Bench `../probes/P-184-a-start-guard-behind-its-own-await.md`.

**Confirmed on `afterModulesStart`, and the lead's `start()` claim is REFUTED.** Three concurrent
`start()` calls answer `ok:x`, because that guard and its assignment sit in one synchronous run with
no await between them — a second caller cannot interleave. The audit read "set after an await" off
the wrong method.

**And the sibling sweep found the same shape with the opposite symptom.** `RpcHttp2Server.start()`
sets `_isRunning` after its bind, and the loser's catch sets it FALSE over the winner's true. So:

- **http**: socket bound, `isRunning` true, zero endpoints, every call UNAVAILABLE — a total outage
  behind a health check that says the port is fine.
- **http2**: socket bound and serving calls, `isRunning` FALSE, and `stop()` gives up on exactly that
  flag — the listener is unreachable for the life of the process.

One cause, and no reading of either symptom would have found the other.

## Mechanism

The slot is claimed SYNCHRONOUSLY, before anything can suspend: `_binding` on http, `_starting` on
http2, checked in the same condition as the old flag and set on the line after it.

Both are released in the bind's catch, because the documented response to "address in use" is to call
again — and both in `stop()`, because a claim that survives a successful bind refuses the restart.

## After

```
rpc_dart_http   TWO concurrent          bound + bound      isRunning=true  endpoints=1  call -> ok:x
rpc_dart_http2  TWO concurrent start()  started + started  isRunning=true  call -> ok:x
                                                                           port free after stop()
```

Both now read as the CONTROL rows.

## Canary

**Two, one per package, because these are two fixes in two codebases.**

```
A. http's claim removed
   WITNESS two concurrent phase-twos still serve calls
     Expected: 'ok:x'
       Actual: 'status 14'

B. http2's claim removed
   WITNESS two concurrent starts leave nothing bound
     Expected: true
       Actual: <false>
     the loser's catch cleared the flag the winner had just set
```

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

**`test:unit` caught my own fix breaking restart, and it is worth recording how.** `_binding`
survives a successful bind by design — that is what makes the guard idempotent — and `stop()` did not
clear it, so `server_lifecycle_cleanup_test`'s restart arm got `actualPort == null` and a null-check
crash. I had written exactly that release into http2's `stop()` in the same sitting and omitted it
here.

> A claim flag has three release points, not one: the failure path, the teardown, and never on
> success. Miss the teardown and the first restart is refused by the fix.

## Not fixed

**Four of B-151's five items are untouched** and the lead stays open for them: the `_transport!`
dereference when `afterModulesStart` runs without `start()` (a null-check crash where a StateError
should name the misuse); `close(force: true)` destroying connections before the promised 503;
`stop()`'s two contradicting comments; and the drain polling `health().details['pendingRequests']`
every 25 ms, the string-keyed metrics pattern `drain.dart` itself criticises. None has a measured
consequence yet.

**The concurrency is synthetic.** Nothing in the framework calls either method twice — `RpcApp`
drives phase one then phase two — so the reachable form of this is a misuse or a supervisor retry,
which is why the symptoms matter more than the odds: both are silent, and one is a leak `stop()`
cannot clear.

**No TLS arm.** http2's secure bind is a different call on the same line; the fix covers both because
the claim precedes the branch, and only the plaintext path was measured.

## Links

Lead `../backlog/B-151-http1-server-lifecycle-defects.md` — item one fixed in both packages, four
items open.
Bench `../probes/P-184-a-start-guard-behind-its-own-await.md` — new, two files.
Negative `../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md` — the grading that picked this
lead first.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [560]`.
