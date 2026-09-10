---
round: 270
verdict: RETRACTED
packages: []
lens: RPC-11
bench: none
commit: yes
---

# Round 270 — a gate that cannot fail is not evidence

**Filed retroactively in round 271.** Committed as `33090229` with no record
here; the text below is that commit's, condensed.

## Target

Round 269's own conclusion, one round old.

## Hypothesis

269 wrote into `config.md` that `melos run test:wasm` validates the PUBLISHED
core. If a local link exists anywhere pub looks, that is false.

## Before

```
rpc_dart_wasm/pubspec.yaml            rpc_dart '>=5.0.0 <6.0.0'
rpc_dart_wasm/pubspec_overrides.yaml  rpc_dart -> ../../core/rpc_dart
```

The second file was added by round 122 for exactly this reason and sits one
directory listing away from the first. `test:wasm` resolves the LOCAL core.

## Mechanism

`pubspec_overrides.yaml` is pub's own override mechanism and does not appear in
`pubspec.yaml` at all, so grepping the one says nothing about the other. Round
269 read one file, found what looked like a conclusion, and asserted it without
checking the mechanism that could invalidate it — rule one applied to myself,
and failed.

## After

The real blind spot is the INVERSE and smaller, and is what `config.md` says
now: wasm is never tested against an OLDER published 5.x, which its constraint
allows. `publish:dry` states that as a hint rather than a warning, so the
release flow's "0 warnings" still holds. To cover it, remove the overrides file
for one run — do not delete it, or the gate goes blind again.

## Canary

n/a

## Gate

n/a — documentation only.

## Not fixed

Nothing. Kept as a retraction rather than a silent edit, because the wrong
version was committed and someone may have read it.

## Links

RPC-11, B-23. The lesson is the one the overrides file itself states: **a gate
that cannot fail is not evidence — check what it RESOLVES.** The observable is
pub's resolution line, not the pubspec. Worth carrying while B-23's other five
dossiers are read: the dossier was right and the journal was wrong, the reverse
of what B-23's procedure assumes.
