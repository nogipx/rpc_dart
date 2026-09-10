---
round: 318
verdict: DEFERRED
packages: [rpc_blob]
lens: RPC-25
bench: none
commit: yes
---

# Round 318 — a lens derivation stopped by scope

## Target

`lenses` mode over `packages/data`, `packages/blob` and `packages/notify` —
B-10's 234 unexamined files — opened on the owner's "you can invent new lenses,
our shared task is a quality library ecosystem".

**Stopped mid-derivation by the owner narrowing scope back to core and
transport.** The record is kept because the enumeration had already produced a
measured finding, and because the shape it found is worth having written down
for whenever B-10 is taken up.

## Hypothesis

These three layers share a structure core and transports do not, so carrying the
existing lenses across would miss what is actually there.

## Before

The enumeration, which is the part that completed:

```
interface                 implementations   packages   in test:unit?
IBlobRepository                 4              4        2 of 4
IDataStorageAdapter             3              3        2 of 3
INotifyRepository               3              3        2 of 3
```

**Ten independent implementations of three interfaces, spread across ten
packages.** Nothing in core or transport looks like this: a pluggable interface
whose guarantees are prose, with each backend written by whoever added it.

And per `config.md`, `*_postgres` and `*_minio` need running services and are
excluded from `melos run test:unit` — so a third of the implementations do not
run in the ordinary gate.

## Mechanism

The first two adapters compared already disagreed.

`IBlobRepository.deleteBlob` promises only *"returns `true` when something was
removed"*. On the same input — blob missing, `expectedVersion` set:

```
in_memory_blob_repository.dart:202   throws StateError
webdav_blob_repository.dart:248      returns false
```

Neither is obviously wrong, because the interface never said. But they are
interchangeable BY DESIGN — that is what the interface is for — so a caller
written against one silently takes the other branch on the other.

Filed as **B-33** with the two more implementations that were not compared, and
the two interfaces that were not looked at at all.

## After

No code changed and no lens was filed. The derivation stopped at the
enumeration.

## Canary

n/a — nothing changed. The finding itself is a direct read of two files at named
lines, and either one contradicts the other or it does not; there is no timing or
load involved.

## Gate

Not re-run: no code changed. Last full gate at round 315's `29acab93` — analyze
clean over 21 packages plus wasm, `test:unit` 14 packages 0 failures, format
clean, licence 1317/1317.

## Not fixed

**B-33**, deliberately, on an owner scope decision — the reason the verdict is
DEFERRED rather than CLEAN. The contradiction is real and measured; it is simply
not in scope.

**The lens is not filed either.** The shape has a name in my head — one
interface, N backends, guarantees in prose, a third of them outside the gate —
but a lens needs a detector proven on the corpus it covers, and the corpus is
out of scope. Filing it now would put an unexercised lens in the set, which is
the thing `lenses` mode exists to avoid. The enumeration above is the durable
part and B-10 can start from it.

## Links

B-10 — unchanged, still deferred; this round confirms the deferral rather than
lifting it. B-33 (new). RPC-25 is named as the lens because the sibling-drift
question is what the comparison ran, even though the target was out of its
declared paths.

What this round records for the loop itself: **an enumeration is worth keeping
even when the round that produced it is abandoned.** The ten-implementations
count and the gate-coverage split cost one grep each and would otherwise be
re-derived from scratch by whoever opens B-10.
