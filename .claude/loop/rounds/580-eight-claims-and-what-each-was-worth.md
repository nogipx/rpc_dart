---
round: 580
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-24
bench: none — the lead's own witness line reads "None"; every claim is about dead or
  misdescribed surface, which a sweep settles and a measurement cannot
budget: probes 0/5, canaries 0/5
commit: yes
release: none
severity: S3
---

# Round 580 — eight claims and what each was worth

## Target

`B-159`, the last non-web isolate lead, and the one whose `## Witness a round would build` says **None**.
Taken knowing it sits below the severity bar the config sets from round 191: it is dead surface, not
damage. What makes it worth a round is that it bundles EIGHT claims, so leaving it open leaves eight
unanswered readings in a package three consecutive rounds have just been inside.

Lens RPC-24: public by omission — surface that exists without anyone deciding it should.

## Hypothesis

Eight separate claims, each true or not by reading.

## Before

The sweep, one line per claim:

```
1 entrypointWrapper is a local closure, capture hazard   TRUE, latent
2 startup relies on the VM draining microtasks           not examined
3 an extra async-broadcast hop per message               not examined
4 isolateId unused                                        HALF TRUE
5 workerUri ignored on the VM                             TRUE
6 runRpcIsolateManagerWorker a no-op                      ALREADY DOCUMENTED
7 the finish message type is unreachable                   TRUE
8 close() unawaited in handlers                            not examined
```

**Claim 4 is the interesting one.** `isolateId` is NOT unused — it builds `debugName` at `:258`. What IS
dead is the copy of it crossing the isolate boundary in the spawn args: `grep args[1]` found no reader.
So the parameter is live and the ARGUMENT was dead, which the lead's one-word summary could not say.

**Claim 6 is refuted as a defect**: `runRpcIsolateManagerWorker` already carries "No-op on the VM: there is
no worker scope to wire up. Exists so the signature matches `isolate_transport_web.dart`". Dead surface
that says why it is dead is documented, not undocumented.

## Mechanism

Nothing is broken. A positional arg nobody reads, a parameter that does nothing on this target, a branch
nothing reaches, and a closure that is safe today for a reason no comment stated.

## After

```
4  the dead arg is GONE, and the wrapper's indices moved down with it
5  workerUri says WEB ONLY, and why it is on both signatures
7  the finish branch says it is unreachable -- and why it is KEPT
1  the wrapper says it captures nothing and must stay that way
```

**Claim 7 is documented rather than deleted, deliberately.** The branch below it DROPS whatever falls
through, so removing the unreachable branch would turn a bare end-of-stream message — if anything ever
sends one — from a frame into a silent loss. A reading is enough to call it unreachable; it is not enough
to make deletion safe.

## Canary

**None, and none is possible: nothing was switched off.** Three of the four changes are comments; the
fourth removes a value nothing reads, and what stands in for a witness there is that **the arg layout is
positional and read by index** — had anything depended on the removed slot, the isolate suite would have
failed on the shifted indices. It passed, `+93`.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_isolate +93
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2203 / 2203, REUSE compliant
```

## Not fixed

**Three claims were not examined and are named rather than quietly dropped**: the startup relying on the
VM draining microtasks between port messages (2), the extra async-broadcast hop per message (3), and
`close()` unawaited in handlers (8). Each is a cost or an ordering question needing its own arm, and this
round's scope was the claims a reading settles.

**Claim 1 is documented, not removed.** Making `entrypointWrapper` top-level would make the capture hazard
structurally impossible, which is strictly better than a comment — but it is a refactor of the one function
that knows the arg layout, with no failing arm to prove it safe, and this round had already changed that
layout.

**The web half is untouched.** The lead names `web_bridge.dart:163, 248, 254`; none of it was read.

## Links

Lead `../backlog/B-159-isolate-fragility-and-dead-parameters.md` — four claims answered, three unexamined,
one documented; the lead stays open.
Round `578-the-transfer-that-cost-more-than-it-saved.md` — the comment this round's arg change sits beside.
Lens `../lenses/RPC-24-public-by-omission.md` — `applied: [580]`.
Lesson: none. What this round applied is the rule that a bundled lead needs its claims separated before any
of them is worked, which is `B-139`'s own note and already written there.
