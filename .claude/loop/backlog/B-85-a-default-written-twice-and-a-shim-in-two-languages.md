---
status: decided by owner (round 445)
round: 453 — Dart half DONE; the native half is untouched
commit: 92bbcff8
paths: [packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
probe: —
reason: owner decision — the native half needs a booted simulator AND emulator. Round 470 found the EMULATOR bootable (`flutter emulators --launch Small_Phone`) and the simulators broken on disk, not forbidden; see B-38
---

# B-85 — a default written twice, and a shim written in two languages

## DART HALF DONE (round 453). Only the native half is left.

13 repeated literals are now one private constant each, used by the constructor
and by `fromMap`. The 14th, `maxMethodPathLength`, already worked that way and is
the idiom the rest follow.

The test the owner asked to keep is `test/core/policy_defaults_agree_test.dart`,
and it earns its place: a literal written back into `fromMap` —
`readInt('maxHeaders', 64)` — fails it with `at location ['maxHeaders'] is <64>
instead of <128>`, naming the field rather than failing an opaque `==`. Only the
EMPTY-MAP arm catches that; the round-trip arms pass, because `toMap` writes the
value and `fromMap` reads it instead of falling back.

The constants are PRIVATE: `public_member_api_docs` wanted a doc comment on each,
and 13 new documented public members is a real addition to a published surface for
something no caller needs to name.

**What is left, and why it is yours**: the JS shim carried as strings in BOTH
`RpcDartWasmPlugin.swift` and `RpcDartWasmPlugin.kt`. Per `config.md` a fix to one
is never a fix to the other, and it needs `analyze:native` plus
`test:wasm:device` on both platforms — a booted simulator and emulator, as with
B-38 and B-03.

Two halves, deliberately kept together because they are one shape — a value with
two homes and nothing checking they agree.

**The Dart half.** Every policy default is written twice:
`security_policy.dart:197-206` in the constructor and `:258-261` in `fromMap`,
with the literal repeated each time (128, 128, 8*1024, 1024, 64*1024, false,
60s, the flow-control windows). Change a default in one and `fromMap` silently
disagrees with the constructor — which matters because `fromMap` is how a policy
crosses an isolate or worker boundary, so the two ends of one process would run
on different limits.

**The copies AGREE today.** This is the one item in B-70's remainder where
"currently agree" is an accurate description, and the failure mode is a future
edit rather than a present defect. The witness is therefore a test that asserts
the two agree, not a fix.

**The native half is a device round.** The wasm JS shim is carried as strings in
BOTH `ios/Classes/RpcDartWasmPlugin.swift` and
`android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt` — two
languages, and per `config.md` a fix to one is never a fix to the other. Neither
`analyze` nor `test` compiles a line of either; it needs `analyze:native` and
`test:wasm:device` on both platforms, with a booted simulator and emulator.

So the halves have very different costs and a round should take the Dart one
alone. Round 444 ranked this third of B-70's three for exactly that reason.

## Owner decision

**The Dart half only: ONE source for the defaults, plus the test.**

The owner took the stronger of the two options offered. A test that asserts the
copies agree was DECLINED as the whole job: it detects the drift, it does not
prevent it, and a value with two homes is the shape this lead is filed under.
So the constructor and `fromMap` are to read the same declared defaults, and
the test stays as the witness that they do.

Keep the test even after the single source lands. It is what fails if someone
re-introduces a literal, and it is cheap.

Bar for "one source": no literal appears twice. If the shape that achieves that
costs more than the drift it prevents — for instance if it forces every default
through a map and loses the constructor's types — bring the trade back rather
than absorbing it.

**The native half is NOT in this decision.** The JS shim carried as strings in
both Swift and Kotlin stays a separate, device-bound job, alongside B-38 and
B-03, and needs the owner to boot a simulator and an emulator.
