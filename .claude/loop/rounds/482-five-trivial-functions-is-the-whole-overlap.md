---
round: 482
verdict: CLEAN
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-123 — new
commit: yes
---

# Round 482 — five trivial functions is the whole overlap

## Target

Whether the two native plugins' JS shims have DRIFTED — a fix applied to one
platform and not ported, which is RPC-06's shape and which this repository has
paid for at least twice (B-38, and the boot-error placeholder that beat the real
V8 message on Android only).

The question was raised by B-93, which **names its own instrument and had never
run it**: *"the instrument is a diff between two string literals in two
languages"*. This round runs it. It does not answer B-93's question — where one
copy should live is the owner's — it measures the premise underneath it, which
is a fact and not a judgement.

## Hypothesis

B-93 states the shim is "the same shim" in both files. If so, the two literals
should be largely identical, and whatever is NOT identical is either drift or a
documented platform difference.

## Before

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

**Nine of fourteen differ or exist on one side only, and the five that match are
trivial** — `queueMicrotask`, `clearInterval` and `clearTimeout` are one line
apiece.

## Mechanism

Nothing changed. The three DIFFERENT bodies are forced by the host, and the two
host-language halves are already in sync:

```
_rpcWasmSendBytes  ios      fetch('rpc-wasm:///send', ...)
                   android  _rpcWasmOutbox.push(_bytesToBase64(bytes))
setTimeout         ios      calls _scheduleNextTick()
                   android  does not — the HOST pulls _tickAndReportNext()
stripModuleSyntax  identical four prefixes, both languages
unstrippedModule…  line-anchored in both, deliberately not a regex
```

iOS runs in a WKWebView: real `fetch`, real timers, `window.webkit.message
Handlers`. Android runs in a bare V8 isolate under androidx.javascriptengine
with none of those, so bytes leave base64 through an outbox the host drains,
console output buffers into an array the host drains, and **the timer driver is
INVERTED** — iOS pushes, Android is pulled.

## After

Unchanged, and deliberately: **no drift was found.** Every difference traces to
the platform rather than to neglect. The round's output is the negative, C-56,
and the correction to B-93's premise.

## Canary

No fix, so nothing to switch off. What stands in its place is that **the
instrument returns both answers on the same run** — 5 IDENTICAL beside 3
DIFFERENT, from one pass over one pair of files, with every difference printed
line by line. An extractor stuck on either verdict cannot do that, and it is
what makes the 5 credible rather than an artefact of over-eager normalising.

## The first run was wrong in both directions

Worth recording, because its output was as tidy as the correct one. The line
ranges were `125..300` and `174..500`; the literals are `125..308` and
`174..367`. So the iOS shim was TRUNCATED and the Android one OVER-RAN into a
second, unrelated `evaluateJavaScriptAsync` literal at `479..485`.

A range into somebody else's file is a premise that nothing checks, and L-15's
shape again: the table printed cleanly either way. The probe now asserts both
endpoints are `"""` delimiters and exits 2 otherwise. Re-run with correct
bounds the numbers were unchanged — the risk was real, the error was not.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. `loop.py lint` green.

No tracked source changed — the probe lives under `.dart_tool/`, which is
gitignored — so the gate could only confirm the tree was where round 481 left
it. Run anyway rather than reasoned about. The probe runs on `dart:io` alone, so
it needs no resolution of the non-member package.

## Not fixed

**B-93 is not decided and must not be read as decided.** Where one copy should
live is the owner's question. What this round changes is its SIZE: option 3 (a
check over the shared region) is now cheap and precise, because that region is
five small functions; options 1 and 2 would move twelve platform-specific
functions across a language boundary in order to de-duplicate five trivial ones.
The lead now carries the measurement so the decision is taken on the tree rather
than on the sentence "the same shim".

**This says nothing about the plugins diverging elsewhere.** B-38 is exactly
that divergence and is still open. The claim is about the JS shim, today, at
`8fd479ea`.

## Links

- RPC-06 — the plugin's native layers, and the contract across a boundary that
  is neither language; `refines: U-14`, compare siblings
- C-56 — the negative this produced
- L-13 — measure the sentence a decision would rest on. Fourth round running,
  and the first where the sentence was measured BEFORE the owner spoke rather
  than after
- L-15 — why the first run's tidy table was not evidence
- B-93, P-123
