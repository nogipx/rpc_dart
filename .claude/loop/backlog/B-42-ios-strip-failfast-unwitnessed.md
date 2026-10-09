---
status: closed (round 365)
round: 363
commit: b1053a84
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift]
probe: packages/transport/rpc_dart_wasm/example/integration_test/unstripped_module_syntax_test.dart
reason: "the iOS half of round 363's fix is compiled but not run: no simulator could be started in eight attempts across this session. The change SHIPPED rather than being reverted, and the reasoning for that asymmetry with round 357 is recorded below so the owner can overrule it"
---

# B-42 — the module-syntax fail-fast is unwitnessed on iOS

## CLOSED, round 365

A simulator came up and the suite ran on it: **all five witnesses pass on iOS**
(`+26`, iOS 18.6), unchanged. The check fires correctly there and the control —
the real glue still booting — holds, so the false-positive risk the Android
ablation priced does not materialise on the other engine either.

The argument below for shipping it unwitnessed turned out to be right, which is
worth recording precisely because it might not have been. What remains
unmeasured is the second paragraph of "What is still unknown": nobody ablated
the check ON IOS to confirm the 30 s watchdog is what it replaces there. That is
a question about the OLD behaviour, not about the fix, and it is not worth a
device run of its own.

---

## What shipped

Round 363 added `unstrippedModuleSyntax` to BOTH plugins: after the four-prefix
strip, the first line whose trimmed start is `export ` or `import ` is reported
as an explicit error naming the construct and `stripModuleSyntax`.

The **Android** half is witnessed by four device tests plus a control, and its
control was ablated (`+21 ~2` → `+3 ~2 -13`).

The **iOS** half is `analyze:native`-clean and has never been run.

## Why it shipped where round 357's did not

Round 357 wrote an iOS recv-loop fix, could not run it, and reverted. The
asymmetry is deliberate and worth stating:

- **357 changed a live path's BEHAVIOUR** — retry, backoff, a new death report
  on a loop that currently works. Unwitnessed, that risks breaking a path that
  is fine today.
- **This changes a path that is already failing.** The check runs once, at load,
  before anything is allocated, on glue that would otherwise reach the engine as
  a syntax error. If the check is wrong in the false-NEGATIVE direction, the
  outcome is exactly today's behaviour.

- **The risky direction is the false POSITIVE** — refusing working glue — and
  that risk lives in the line-anchoring rule, which is identical in both
  languages and IS measured. The Android ablation shows what a wrong rule costs:
  thirteen dead tests. The rule that passes it is the same rule Swift runs, on
  the same bytes, and both are written without a regex precisely so the two
  engines cannot disagree.

That is an argument, not a measurement, which is why this lead exists.

## What is still unknown on iOS

1. **Whether the check fires correctly there at all.** The Swift implementation
   uses `split(separator:omittingEmptySubsequences:)` + `drop(while:)` +
   `hasPrefix`. Compiled, never executed.
2. **What it replaces.** The Swift source says a SyntaxError in the glue kills
   the whole `<script>` tag, so the IIFE never defines `compile` and the failure
   surfaces as the 30 s boot watchdog blaming something else. That is the
   symptom the review item predicted — and it is PREDICTED, not measured. On
   Android the old message already named the token, so the item's premise did
   not hold there.

## Owner decision

**Whether shipping the unwitnessed iOS half was the right call.** Round 363 made
it on the reasoning above and records it here precisely so it can be overruled:
if you would rather the Swift check waited for a device, revert
`unstrippedModuleSyntax` and its call site in `RpcDartWasmPlugin.swift` and
leave the Android half, which stands on its own.

No decision is needed to close the lead itself — that needs a simulator, not a
choice.

## How to close it

Boot a simulator and run
`RPC_WASM_DEVICE=<id> melos run test:wasm:device`. The test is already in the
suite and platform-agnostic: the four witnesses and the control run unchanged.
If they pass on iOS, this lead closes with nothing to change.

Worth capturing in the same run: what the BEFORE state reports on iOS, by
ablating the check as the Android canary did. If it is the 30 s watchdog, the
item's original framing is confirmed for iOS and the fix is worth more there
than the Android numbers suggest.
