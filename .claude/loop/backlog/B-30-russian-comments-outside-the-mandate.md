---
status: decided by owner (round 415)
round: 303
commit: 139bca2a
paths: [packages/core/*/test/**, packages/core/*/example/**, packages/transport/*/test/**, packages/transport/*/example/**, packages/data/rpc_data/lib/**, packages/data/rpc_data_sqlite/lib/**, packages/blob/rpc_blob/lib/**, packages/notify/rpc_notify/lib/**]
probe: none
reason: decided — sweep the 47 test/ and example/ files inside core+transport first; the 23 lib/ files are all outside the mandate and wait
---

# B-30 — Russian comments in packages outside the mandate

The root `CLAUDE.md` states the rule plainly:

> ## Style
> - English for code, comments, and logs.

Round 303 found `rpc_http2_server.dart` written in Russian throughout — class
doc, constructor doc, every log string — and fixed it as part of the http2
sweep. The check that confirmed the file was clean afterwards found the same
thing in **25 lib files**, and only three of them are in the mandate.

Measured with `grep -rlE "[А-Яа-яЁё]" packages/*/*/lib`, after round 303:

    packages/data/rpc_data/lib/            16 files
    packages/blob/rpc_blob/lib/             3 files
    packages/data/rpc_data_sqlite/lib/      3 files
    packages/notify/rpc_notify/lib/         1 file
    packages/transport/rpc_dart_http2/lib/  2 files   <- round 304 covers these

`rpc_data` is the worst: the Cyrillic is in `models.dart`, `data_contract.dart`,
the repository interfaces and the client — the API surface a user of that
package reads first. One of the 16 is `data_contract.g.dart`, which is
GENERATED, so fixing that one means fixing the generator's template or the
source contract, not the file.

## Why this is a real defect and not a preference

It is the project's own written rule, so this is rule one applied to prose: the
implementation (the repo's stated style) and the code diverge. And it is not
cosmetic on a PUBLISHED package — all 22 are on pub.dev, so these doc comments
are what dartdoc renders on the package page for an audience the rule says is
English-speaking.

## Why round 303 did not do it

The owner's mandate is five packages in a stated order, and these are none of
them. Sweeping four unrelated packages mid-mandate would be the round choosing
its own scope; `rpc_data` alone is 16 files and would be a round of its own.

## What it would cost

One round per package, probably two for `rpc_data`. Mechanical but not
automatic: the log strings are user-visible output, and a few of the comments
are the only description of the behaviour they sit on, so they need translating
rather than deleting. `grep -rlE "[А-Яа-яЁё]"` is the detector and the check.

The generated file needs its source found first — that is the only part that is
not a straight edit.

## Owner decision

**Taken: sweep the in-scope half first — the 47 `test/` and `example/` files in
core and transport. The 23 `lib/` files wait.**

Re-counted by hand in the backlog review, because both earlier numbers in this
record had drifted:

```
lib/                       23   data/rpc_data 16, data/rpc_data_sqlite 3,
                                blob/rpc_blob 3, notify/rpc_notify 1
test/ + example/           47   core and transport
```

Two things that changes. **The three http2 files this record named are gone** —
swept incidentally by rounds working in that package, so the `lib/` half is now
entirely OUTSIDE the mandate. And the in-scope half is the larger one: 47
against 23.

`grep -rl "[а-яА-Я]" --include="*.dart"` is both the detector and the check.
Translate rather than delete — several of these comments are the only
description of the behaviour they sit on.

The `lib/` remainder keeps its own reason and is not closed: 16 of its files are
`rpc_data`'s `models.dart`, contract and repository interfaces, which is a
PUBLISHED API surface that dartdoc renders. One is generated, so that one means
finding the generator's source first.

## Round 432 — the example half is done, and the real number is LINES

**47 files is 1817 Cyrillic lines.** The recount above fixed the file count and
still measured the wrong thing: translating properly — which this record itself
demands, *"translate rather than delete"* — is per line, and 1817 is not one
round's work. Saying so before starting is what L-12 is for.

```
                            before   after
example/, core + transport   529      0     10 files, round 432
test/, core + transport     1288   1288     37 files, open
```

The examples went first because `example/` is published to pub.dev and is the
first thing a reader evaluating the package meets; test comments are internal.
Emoji were removed in the same pass, including from the text these programs
PRINT, which is output rather than source.

**What the test half needs that the examples did not**: several of the 1288
lines are test NAMES, and renaming one changes what the suite reports. That is
a different kind of edit from a comment and is worth deciding deliberately.
