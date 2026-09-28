---
status: open
round: 474
commit: 44de5182
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — the instrument is a diff between two string literals in two languages
reason: cost — split out of B-85, whose owner decision says in as many words "The native half is NOT in this decision". Undecided, not blocked
---

# B-93 — the guest's JS shim is written twice, in two languages

Split out of B-85 in round 474. That lead's decision covered the Dart half — one
source per policy default — and ends *"The native half is NOT in this decision.
The JS shim carried as strings in both Swift and Kotlin stays a separate,
device-bound job."* B-85 is closed; this is what it was carrying.

## The shape

The JS that boots a dart2wasm guest is a string literal inside each plugin:

```
ios/Classes/RpcDartWasmPlugin.swift                       bootHtml, a Swift """
android/.../RpcDartWasmPlugin.kt                          the same shim, Kotlin
```

Two languages, no shared file, and `config.md` states the consequence: a fix to
one is never a fix to the other. The repository has already paid for this at
least twice — the recv-loop reporting Android has and iOS does not (B-38), and
the boot-error placeholder that beat the real V8 message on Android only.

## Not device-blocked any more

Rounds 470 and 472 got both a simulator and an emulator running, and
`test:wasm:device` is green on both (`+26` iOS, `+24 ~2` Android). So the
*verification* this needs is available. What is missing is a decision.

## The decision the owner has to make first

**Where would the one copy LIVE?** The two plugins share no build system and no
language. The candidates, none obviously right:

1. **A Dart string in `rpc_dart_wasm`, passed down** through the existing
   `jsBootPrefix` channel. One source, and it moves the shim into the package's
   public-ish surface; the plugins keep a minimal bootstrap each.
2. **A `.js` asset** bundled and read by both plugins. One source, but it adds a
   file-loading path to two native plugins that currently need none, and an asset
   that fails to load is a new failure mode on a path whose whole difficulty is
   that it fails silently.
3. **Leave it, and add a CHECK** that the two strings agree on the parts that
   must — a test that extracts both and diffs the shared region. Detects drift
   without preventing it, which is the option B-85's owner explicitly declined
   for the Dart half.

Option 3 is cheap and the owner rejected its analogue; options 1 and 2 both move
code across a language boundary on the one path where a silent failure is the
established failure mode. That is why this is a decision and not a round.

## What a round would then do

`analyze:native` for the type-check and `test:wasm:device` on BOTH platforms for
the evidence — two boot scripts in two languages, so one run proves one of them.

## Owner decision

—
