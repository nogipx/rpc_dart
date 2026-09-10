---
round: 291
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: none
commit: yes
---

# Round 291 — the boundary, drawn

## Target

Step 0 and step 1 of the mandate together, because 290 proved they are one edit:
re-point core's internal imports, then narrow the public barrel.

## Hypothesis

290 found that eleven `lib/` files import `package:rpc_dart/rpc_dart.dart`, so
the public barrel is a dependency of the implementation and cannot be narrowed.
Give the implementation its own barrel and that stops being true.

## Before

```
public top-level types (round 289)      152
lib/ files importing the public barrel   11
analyzer errors when hiding 13 types     78   (7 inside lib/)
```

## Mechanism

`lib/src/_internal.dart` is what `lib/rpc_dart.dart` used to be —
`dart:typed_data`, `logger.dart`, `_index.dart`, no view on what is public. The
eleven files import that instead. The public barrel is then free to `hide`,
because nothing inside the library reads it any more.

Relative imports on purpose (`../_internal.dart`), not `package:` — the
implementation should not address itself through its own package name.

## After

```
types hidden from the public barrel      13
public top-level types                  139   (152 - 13)
lib/ files importing the public barrel    0
analyzer, rpc_dart lib+test              No issues found!
analyzer, all 21 packages + wasm         No issues found!
```

Hidden: `CallProcessor`, `StreamProcessor`, both pipeline mixins,
`RpcResponderStreamState`, `RpcResponderStreamStore`,
`RpcResponderMethodRegistry`, `RpcResponderMethodBinding`,
`RpcResponderPingHandler`, `RpcEndpointPingProtocol`, `RpcEndpointPingExchange`,
`RpcEndpointPingResult`, `RpcLongTimer`.

Deliberately NOT hidden: `RpcMessageParser`, `RpcMessageHeader`,
`BufferedBroadcastController` — all four transports build on them, so they are
the transport-authoring API, not internals. That distinction came from 289's
measurement of who uses what, and this round confirms it: **no dependent package
broke.** 21 packages analysed clean against the narrowed barrel.

Fourteen core tests now import `package:rpc_dart/src/_internal.dart` instead of
the public barrel — and once they did, the analyzer flagged the public import as
redundant in every one of them, which is the boundary reporting itself: a test
that reaches internals has no business holding the public API too.

## Canary

n/a for a visibility change — the analyzer IS the witness, and it was run in
both directions. With the `hide` and without the internal barrel: 78 errors, 7
of them inside `lib/`. With both: clean, across every package in the workspace.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.

## Not fixed

Steps 3 and 4 of the mandate for this package: the `dart:typed_data`
re-export, and then the doc comments for the 139 that remain.

`dart:typed_data` is now the last structural item — every transport still gets
`Uint8List` from `package:rpc_dart/rpc_dart.dart` by accident, and removing it
is one added import per affected file across five packages.

## Links

RPC-04 (`applied:` gains 291). Rounds 289 (the measurement) and 290 (the failed
attempt that found the prerequisite) are what made this one a single clean edit.
