---
round: 292
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: none
commit: yes
---

# Round 292 — nobody was using the re-export

## Target

Step 3, the last structural item for `rpc_dart`: `lib/rpc_dart.dart` line 8 was
`export 'dart:typed_data';` — a package re-exporting an entire SDK library.

## Hypothesis

Round 289 wrote, and 291 repeated: *"every transport currently gets `Uint8List`
from `package:rpc_dart/rpc_dart.dart` by accident, and removing it is one added
import per affected file across five packages."* Both rounds treated that as the
reason to leave it until last.

## Before

```
export 'dart:typed_data';   lib/rpc_dart.dart:8
```

## Mechanism

n/a — the hypothesis was wrong, and that is this round's whole content.

## After

The line is gone.

```
analyzer, all 21 packages + wasm     No issues found!
errors                                       0
files needing a new import                   0
```

**Nobody depended on it.** Every file that uses `Uint8List` already imports
`dart:typed_data` itself. The "one added import per affected file across five
packages" that two rounds planned around does not exist.

Core's own implementation is unaffected for a different reason: `_internal.dart`
still exports `dart:typed_data`, so `lib/` keeps it deliberately rather than by
accident — which is the distinction round 291 built that barrel for.

## Canary

n/a for a visibility change; the analyzer is the witness, over 21 packages plus
the out-of-workspace wasm one.

## Gate

`melos run analyze`, `melos run test:unit --no-select`, `melos run format:check`,
`melos run license:check` — all green.

## Not fixed

Nothing structural. `rpc_dart`'s boundary work is done: 152 -> 139 public types,
no internal file importing the public barrel, no SDK library re-exported.

What remains for this package is step 4, the doc comments for the 139 that
survive — and that is a different kind of work, best measured by counting what
is undocumented rather than by counting errors.

> **Two rounds planned around a cost nobody had measured.** 289 asserted the
> blast radius from reading the export line, 291 repeated it, and it was zero.
> The rule this repository already has — never rely on prose, measure — applies
> to a round's own prose about the NEXT round just as much. Cheap to check,
> and checking it turned a deferred multi-package edit into a one-line deletion.

## Links

RPC-04 (`applied:` gains 292). Rounds 289 and 291 are the ones this corrects.
