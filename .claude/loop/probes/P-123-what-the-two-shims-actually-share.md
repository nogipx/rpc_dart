---
file: packages/transport/rpc_dart_wasm/.dart_tool/probe/what_the_two_shims_actually_share.dart
round: 482
commit: 8fd479ea
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
status: valid
---

# P-123 — what the two JS shims actually share

## Why it exists

B-93 says the JS that boots a dart2wasm guest is "the same shim" carried as a
string literal in Swift and again in Kotlin, and **names its own instrument**:
*"the instrument is a diff between two string literals in two languages"*.
Nothing had ever run it. All three of the lead's options rest on there being one
shim to de-duplicate, so the premise was worth a number before the owner decides.

## The harness

Extracts every top-level `function NAME(...)` body from each literal by BRACE
MATCHING, normalises indentation, and sorts the names into four buckets:
`IDENTICAL`, `DIFFERENT` (same name, different body), `iOS ONLY`,
`ANDROID ONLY`.

Brace matching rather than a regex because several bodies contain nested
closures and object literals, and a non-greedy match stops at the first inner
`}` — which silently compares a PREFIX and reports IDENTICAL.

Normalising indentation is not cosmetic either: the two literals sit at
different nesting depths in their host files, so a byte comparison reports 100%
drift and means nothing.

## The numbers (round 482)

```
iOS functions     14
Android functions 14

IDENTICAL     5   _flushMicrotasks, _rpcWasmReceiveBytes, clearInterval,
                  clearTimeout, queueMicrotask
DIFFERENT     3   _rpcWasmSendBytes, setInterval, setTimeout
iOS ONLY      6   _rpcOnFailure, _rpcReportBoot, _runDueTimers,
                  _scheduleNextTick, _startRecvLoop, poll
ANDROID ONLY  6   _base64ToBytes, _bytesToBase64, _rpcDrainConsole,
                  _rpcWasmDrainOutbox, _rpcWasmReceiveBytesB64,
                  _tickAndReportNext
```

Every DIFFERENT is printed line by line. All three are host-API differences:

```
_rpcWasmSendBytes  ios      fetch('rpc-wasm:///send', {method:'POST', body:bytes})
                   android  _rpcWasmOutbox.push(_bytesToBase64(bytes))
setTimeout         ios      calls _scheduleNextTick()
                   android  does not — the HOST pulls via _tickAndReportNext()
setInterval        same split as setTimeout
```

## Measures

Function-level identity between two string literals, by name and normalised
body. Not a similarity percentage: the useful question is which named things
could be ONE thing, and that is a set, not a ratio.

## Control

**The instrument produces both answers on the same run** — 5 IDENTICAL beside 3
DIFFERENT, from one pass over one pair of files. An extractor stuck on either
verdict cannot do that, which is what makes the 5 credible rather than an
artefact of over-eager normalising.

**A bounds assertion, added after the first run was wrong in both directions.**
The ranges were `125..300` and `174..500`; the real literals are `125..308` and
`174..367`. So iOS was TRUNCATED and Android OVER-RAN into a second, unrelated
`evaluateJavaScriptAsync` literal at `479..485`. The table it printed looked
exactly as tidy as the correct one. The probe now checks that both range
endpoints are `"""` delimiters and exits 2 if not — a line inserted in either
host file otherwise turns this into a comparison of two arbitrary slices.

(Re-run with correct bounds, the numbers were unchanged: `_rpcWasmReceiveBytes`
is genuinely defined in both boot literals. The risk was real; the error was
not.)

## What it establishes, and what it does not

Establishes: **B-93's premise is false.** These are not one shim written twice.
Of 14 named functions each, only 5 are shared and identical and all five are
trivial — `queueMicrotask`, `clearInterval` and `clearTimeout` are one line
apiece. Nine of fourteen differ or exist on one side only, and every difference
traces to the host: iOS runs in WKWebView with real `fetch`, real timers and
`window.webkit.messageHandlers`; Android runs in a bare V8 isolate under
androidx.javascriptengine with none of those, so bytes go out base64 through an
outbox the host drains, and **the timer driver is INVERTED** — iOS pushes, the
Android host pulls.

Establishes: **no drift.** Every difference is explained by the platform, not by
a fix applied to one side and forgotten on the other.

Does NOT establish anything about object-literal methods. The `console` shim is
`log: function() {...}` with no name, so the regex does not see it; it too
differs by platform (`window.webkit.messageHandlers.rpcConsole` against a
`_rpcConsoleLog` array the host drains) and is another forced difference rather
than a candidate for sharing.

Does NOT decide B-93. Where one copy should live is the owner's question; this
only measures how much "one copy" would cover.
