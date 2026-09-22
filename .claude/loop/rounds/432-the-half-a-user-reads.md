---
round: 432
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2, rpc_dart_isolate]
lens: RPC-23
bench: none — a translation sweep; the evidence is a grep count before and
  after, and the gate
commit: yes
---

# Round 432 — the half a user reads

## Target

**B-30**, decided: sweep the Russian comments in the 47 `test/` and `example/`
files of core and transport. Taken after checking B-70 first and finding its
two named items already closed — see `## Not fixed`.

**The lead counted FILES and this round counted LINES, and that changed the
scope.** 47 files is 1817 Cyrillic lines. Translating those properly — the lead
says *"translate rather than delete, several of these comments are the only
description of the behaviour they sit on"* — is not one round's work, and
saying so up front is the rule L-12 exists for.

So the scope is the **10 example files, 529 lines**: complete, self-contained,
and the half a user actually reads, since `example/` ships to pub.dev and is
the first thing anyone browsing the package sees. Test comments are internal.

## Hypothesis

n/a — the defect is not in dispute, only its size. What needed measuring was
the volume, and it is four times what the file count suggests.

## Before

```
in scope (core + transport)     1817 Cyrillic lines across 47 files
  example/                       529 lines across 10 files   <- this round
  test/                         1288 lines across 37 files
```

## Mechanism

Not a defect in behaviour. `example/` is published documentation: a reader
evaluating the package meets these files before any prose, and half of each one
was in a language they may not read. Several also carried emoji, which the
standing requirements forbid everywhere.

## After

```
example/, core + transport      0 Cyrillic lines across 10 files
```

Translated, not deleted — every comment kept its meaning, including the ones
that explain a real constraint: *"a fresh Stream each time, or the second
listen throws already listened to"*, *"codecs must not be passed in zero-copy
mode"*, *"required: call the parent dispose()"*.

Emoji removed in the same pass, and printed output rewritten with them: these
files print what they do, so the emoji were in the program's output, not only
its source.

## Canary

None applicable, and the reason is the round's shape: a translation changes no
behaviour, so there is nothing to switch off. What stands in for it:

```
grep -rl "[а-яА-Я]" example/     0 files      (was 10)
melos run analyze                SUCCESS
melos run test:unit              SUCCESS
melos run format:check           SUCCESS
```

The detector IS the check, which is what B-30 says: *"`grep -rl "[а-яА-Я]"
--include="*.dart"` is both the detector and the check."*

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1607/1607
```

## Not fixed

**1288 lines across 37 `test/` files remain**, and that is the number the next
round starts from rather than a file count. They are internal, so the value per
line is lower than the examples', and several are test NAMES — changing one
changes what the suite reports, which is a different kind of edit from a
comment.

**The 23 `lib/` files stay out of scope**, unchanged from the lead: 16 are
`rpc_data`'s published API surface that dartdoc renders, and one is generated.

**B-70 was checked first and has nothing to take.** Its BACKLOG index line says
*"34 and 23 are the two worth taking next"* — both were closed by round 419,
and the lead's own body says so at "Two more closed — round 419". The index
line is stale against the file it indexes; corrected in this commit. The lead's
remaining 17 items are duplication whose copies AGREE, which its own text calls
"the behavioural half of this lead is now spent".

## Links

- B-30 — the example half done; the test half open with a line count
- B-70 — checked, nothing to take; its index line corrected
- L-12 — count the class before fixing it. The lead counted files; the useful
  number was lines, and it is 4x larger
- RPC-23 — the narrative beside the code, which is what an example IS
