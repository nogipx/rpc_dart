---
status: open
round: 303
commit: 139bca2a
paths: [packages/data/rpc_data/lib/**, packages/data/rpc_data_sqlite/lib/**, packages/blob/rpc_blob/lib/**, packages/notify/rpc_notify/lib/**]
probe: none
reason: "scope — the owner's mandate names five packages in order (rpc_dart, websocket, http, isolate, http2) and these are none of them; sweeping 22 files in four unrelated packages is a different job from the one that was asked for"
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

—
