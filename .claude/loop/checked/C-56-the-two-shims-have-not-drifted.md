---
round: 482
commit: 8fd479ea
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
scope: [rpc_dart_wasm]
probe: ../probes/P-123-what-the-two-shims-actually-share.md
---

# C-56 — the two JS shims have not drifted, and are not one shim

## The claim checked

B-93: the guest's JS shim is written twice, in two languages, so *"a fix to one
is never a fix to the other"* — and the repository *"has already paid for this
at least twice"*. The implied defect is DRIFT: a fix applied to one platform and
not ported.

## What was measured

Every top-level named function in both boot literals, compared by normalised
body (P-123).

```
IDENTICAL     5   all trivial — queueMicrotask, clearInterval and clearTimeout
                  are one line apiece
DIFFERENT     3   _rpcWasmSendBytes, setTimeout, setInterval
iOS ONLY      6
ANDROID ONLY  6
```

## The answer: no drift, and the premise is wrong

All three DIFFERENT bodies are forced by the host API, and both host-language
halves are in sync:

- `_rpcWasmSendBytes` — `fetch('rpc-wasm:///send')` against
  `_rpcWasmOutbox.push(_bytesToBase64(bytes))`. iOS has a WKWebView with a custom
  URL scheme; Android has a bare V8 isolate with no `fetch` at all.
- `setTimeout` / `setInterval` — iOS calls `_scheduleNextTick()`; Android does
  not, because **the timer driver is inverted**. iOS schedules itself through
  `_nativeSetTimeout`; the Android host PULLS by calling `_tickAndReportNext()`,
  which returns the next delay.
- `stripModuleSyntax` — the same four literal prefixes in both languages, and
  `unstrippedModuleSyntax` is line-anchored in both, deliberately not a regex so
  the two agree.

So the twelve one-sided functions are not neglect: they are the two transport
models. `_startRecvLoop`/`poll`/`_rpcReportBoot`/`_rpcOnFailure` need WKWebView;
`_bytesToBase64`/`_base64ToBytes`/`_rpcWasmDrainOutbox`/`_rpcDrainConsole`/
`_tickAndReportNext` exist because the Android sandbox has no fetch, no window
and no native timers.

**The shared surface is 5 trivial functions.** "The same shim written twice" is
not what is in the tree.

## Control

**The instrument returns BOTH verdicts on the same run** — 5 IDENTICAL beside 3
DIFFERENT, from one pass over one pair of files, with every difference printed
line by line. That is what makes "5 identical" a measurement rather than an
artefact of over-eager normalising: an extractor that collapsed everything would
report 14 identical, and one that collapsed nothing would report 0.

**The extraction is brace-matched, not regex-bounded.** A non-greedy match stops
at the first inner `}`, which compares a PREFIX and reports IDENTICAL on bodies
that diverge after their first nested closure — several of these have one.

**The line bounds assert themselves.** The first run used `125..300` and
`174..500` against real literals of `125..308` and `174..367`, truncating iOS
and over-running Android into a second unrelated literal, and printed a table as
tidy as the correct one. The probe now checks both endpoints are `"""`
delimiters and exits 2 otherwise, so a stale range fails loudly instead of
comparing arbitrary slices.

## What this does NOT say

It does not say the two plugins have never diverged by neglect — B-38 is exactly
that, and the boot-error placeholder was another. It says the JS SHIM has not,
today, at `8fd479ea`.

It does not decide B-93. It resizes it: option 3 (a drift check over the shared
region) is now cheap and precise because that region is five small functions,
while options 1 and 2 would move twelve platform-specific functions across a
language boundary to de-duplicate five trivial ones. That is the owner's call
and this is only the measurement under it.

## Re-run it with

`fvm dart run packages/transport/rpc_dart_wasm/.dart_tool/probe/what_the_two_shims_actually_share.dart`

It asserts its own line bounds and exits 2 if either literal has moved, so a
stale range cannot print a tidy and meaningless table — which is exactly what
the first run did.
