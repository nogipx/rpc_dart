---
round: 493
verdict: DEFERRED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — the witness needs the sandbox process killed from the HOST, and the process could not be identified on the emulator in five runs
commit: yes
severity: S2
---

# Round 493 — the instrument is built, the kill is not

## Target

B-102, ninth in the audit's rank, taken in sequence while the emulator from
round 492 was warm. Lens RPC-06.

## Hypothesis

With no timers pending the Kotlin driver parks on `waker.await()`. If the sandbox
dies then, nothing reports it, so every later call waits out its own deadline
against a runtime that cannot answer.

## Before

No number. What the round establishes is a READING over four sites, each
verified, and a reading is not a finding — it is why the lead stays open:

1. `setOnTerminatedCallback`, `addOnTerminated` and `IsolateStartupParameters`
   appear NOWHERE under `android/` (grep, empty). So androidx has no callback
   through which it could tell us.
2. `startDriver` parks on `waker.await()` when `tickAndDrain` returns null, and
   its `catch` — which does call `reportDeath` — can only fire on an exception
   from an evaluation IN FLIGHT. Parked, there is none.
3. `wakeDriver(runtimeId)` is the LAST statement of `forwardBytesToRuntime`,
   after the `.await()` that throws when the isolate is gone, so a throwing
   forward skips it.
4. `registerByteChannel`'s catch logs `Forward to $runtimeId dropped` and then
   `reply.reply(null)` in its `finally` — so Dart's `send` resolves as SUCCESS
   over a dead runtime.

Taken together there is no path by which an idle death could be noticed. That is
the lead's claim restated with its sites checked, not measured.

**One concern of my own, raised and refuted in the same round**: the sketch says
to route the forward's catch to `reportDeath` for `IsolateTerminatedException`,
and the code's own comment says an ordinary close with traffic in flight is the
common way to get that exception — so the sketch looked like it would report a
death for every orderly close. It would not: `closeRuntime` removes the id from
`runtimes` BEFORE closing the isolate, and `reportDeath` opens with
`if (!runtimes.containsKey(runtimeId)) return`. The guard is already there.
`closeRuntime` also calls `wakeDriver` itself, so our own close un-parks the
driver. **The gap is external death only.**

## Mechanism

Not measured. See above for why the reading points where it does.

## After

n/a — nothing changed in `lib/` or the plugin.

## Canary

n/a — no fix.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant. The new test is `skip`ped by default, so
`test:wasm:device` is unaffected — verified by the run in round 492 being the
last unconditional one.

## Not fixed

**B-102 itself, for want of a bench**, and the reason is specific rather than
general: the witness needs the sandbox process killed from the host while the
test sits in an idle window, and a test running ON the device cannot kill it.

What was tried, five device runs:

- A probe outside `integration_test/` — refused, `integration_test plugin was
  not detected`, so the instrument has to live in that directory. It does now,
  behind `--dart-define=rpcWasmKillProbe=true` so the unattended suite skips it.
- Three runs with the 40 s window open, sampling `adb shell ps -A` for
  `sandboxed`, `nogipx`, `rpc_dart_wasm` and `webview`. Only `webview_zygote`
  ever appeared. The app's own process and any sandboxed child were not found in
  the window, so nothing could be killed and every arm read
  `death: NONE, closed: false, after-kill call: echo:b after 84ms` — the runtime
  was alive, because nothing had killed it.

**What the next round needs is one fact**: the name of the JavaScriptSandbox
service process on this emulator image. `webview_zygote` is its parent, so its
child is the target.

**And the obstacle is probably not timing, which is what I assumed for four of
the six runs.** A sample taken 88 s in — inside the window, with the test
demonstrably past its first successful call — showed `webview_zygote` and nothing
else: not the sandbox child, and **not the example app's own process either**,
though it was plainly running. `adb shell ps -A` is not seeing this app's
processes on this image, so `ps` is the wrong instrument rather than a mistimed
one. `pidof` and `dumpsys activity processes` are where the next round starts,
and confirming it can see the APP comes before hunting the sandbox.

## Links

Lens RPC-06. Lead B-102 (open, with the instrument and the five attempts written
into it). Round 492 is the previous round on this plugin and left the emulator
warm.
