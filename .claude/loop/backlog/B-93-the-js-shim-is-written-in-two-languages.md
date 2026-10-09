---
status: closed (round 484)
round: 474
commit: 44de5182
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — the instrument is a diff between two string literals in two languages
reason: cost — split out of B-85, whose owner decision says in as many words "The native half is NOT in this decision". Undecided, not blocked
---

# B-93 — the guest's JS shim is written twice, in two languages

## CLOSED by the owner (round 484) — and round 482 had already dissolved it

*"Close them so they stop getting in the way."* This is the cleanest of the four
closures, because the measurement below had already removed most of its reason
to exist.

The lead was filed on duplication. There is not much: of 14 named functions each,
**5 are identical and three of those are one-liners**. Every other difference is
forced by the host API, and there is no drift (C-56). De-duplicating would move
twelve platform-specific functions across a language boundary to unify five
trivial ones.

The title remains literally true and materially misleading; the measurement
underneath it is the part worth keeping, and it stays here.

## MEASURED (round 482) — the title is wrong, and the decision is smaller than it looks

This lead named its own instrument — *"a diff between two string literals in two
languages"* — and it had never been run. Run (P-123), it refutes the premise all
three options below rest on. **These are not one shim written twice.**

```
iOS functions     14        Android functions 14

IDENTICAL     5   _flushMicrotasks, _rpcWasmReceiveBytes, clearInterval,
                  clearTimeout, queueMicrotask
DIFFERENT     3   _rpcWasmSendBytes, setInterval, setTimeout
iOS ONLY      6   _rpcOnFailure, _rpcReportBoot, _runDueTimers,
                  _scheduleNextTick, _startRecvLoop, poll
ANDROID ONLY  6   _base64ToBytes, _bytesToBase64, _rpcDrainConsole,
                  _rpcWasmDrainOutbox, _rpcWasmReceiveBytesB64,
                  _tickAndReportNext
```

Nine of fourteen differ or are one-sided, and the five that match are trivial —
`queueMicrotask`, `clearInterval` and `clearTimeout` are one line apiece. Every
difference is forced by the host, not by neglect: iOS is a WKWebView with real
`fetch`, real timers and `window.webkit.messageHandlers`; Android is a bare V8
isolate with none of those, so bytes leave base64 through an outbox the host
drains and **the timer driver is inverted** — iOS pushes, the Android host pulls
`_tickAndReportNext()`.

**And there is no drift** (C-56). Both host-language halves agree too:
`stripModuleSyntax` is the same four prefixes and `unstrippedModuleSyntax` is
line-anchored in both, deliberately not a regex so the two cannot diverge.

### What that does to the three options

It does not choose between them — that is still the owner's. It resizes them:

- **1 and 2** would move twelve platform-specific functions across a language
  boundary in order to de-duplicate five trivial ones.
- **3** is cheaper and sharper than when this lead was written, because the
  region a check would cover is now known and small.

The cost this lead was filed on is real but it is not the JS shim: what a fix to
one platform misses is the *platform-specific* code, which no single copy can
cover. B-38 is that, and it is a different lead.

`../rounds/482-five-trivial-functions-is-the-whole-overlap.md`,
`../probes/P-123-what-the-two-shims-actually-share.md`,
`../checked/C-56-the-two-shims-have-not-drifted.md`.

## As filed (round 474)

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
