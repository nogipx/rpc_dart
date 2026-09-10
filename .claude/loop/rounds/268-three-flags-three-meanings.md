---
round: 268
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-19
bench: none
commit: no
---

# Round 268 — three flags, three meanings

## Target

RPC-19, `swept here (round 238)`, with one file moved under it since — the
cheapest defect hunt on the board, and the moved file is
`client_connection.dart`, which rounds 240, 242 and 266 all edited.

## Hypothesis

Those three rounds added or overloaded a lifecycle flag, which is what this lens
exists to catch.

## Before

The diff first, because a stale sweep is about the drift and not the tree:

```
files moved under the lens since 9cbd2d47        1
lines in that diff touching _closed / _isStopped / _disposed   0
```

Then the vocabulary the 238 sweep recorded, re-read at HEAD:

```
_closed      written only by close():313          terminal
_isStopped   connect():434, forceReconnect():447 -> false
             disconnect():459, dispose():468     -> true
_disposed    dispose() only                       irreversible
```

No bench: the detector is "list the writers of each flag and ask whether they
mean the same thing", and the answer is read from the code.

## Mechanism

n/a — nothing found. Three flags, three distinct meanings, none overloaded. The
shape this lens names is a flag whose four readers want four different answers;
here each flag answers one question.

## After

n/a

## Canary

n/a. Worth saying what makes this sweep weaker than the 238 one: that round
drove the recovery API twice and watched it fail the second time. This is a
reading of writers, and its strength is only that the drift it covers is one
file and zero relevant lines.

## Gate

Nothing shipped; the tree at 847d53d2 is green.

## Not fixed

Nothing found. The sweep's sha moves to 847d53d2 so the next `stale` measures
from here rather than re-reporting a file already checked.

## Links

Lens RPC-19, re-swept · the shape it refines is catalog U-18 · rounds 240, 242
and 266 are the edits this checked.
