---
round: 362
verdict: INCONCLUSIVE
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-53 — new
commit: yes
---

# Round 362 — the thread was not the cost

## Target

The owner's 6.0.0 review list, P1 item 11: move Android's Base64 and buffer
copies off `Dispatchers.Main`. Taken now because an Android emulator came online
mid-session — the first time this round's bench was runnable at all.

RPC-06, whose Ask is *was this code RUN, or only read and compiled?* Round 357
answered "compiled" and stopped. This round RAN it, five times, and the answer
was not the one the item predicted.

## Hypothesis

`CoroutineScope(Dispatchers.Main)` puts every Base64 call and buffer copy on the
thread that dispatches every platform channel in the app. If that work is the
cost, moving it to `Dispatchers.Default` should make the main thread measurably
more available during a large transfer.

It fails to hold if the occupancy comes from something else on that thread.

## Before

```
run  state        payload  idle worst  busy worst  idle>16ms  busy>16ms
1    before fix   4 MiB    22ms        59ms        1          2
```

Probe: `packages/transport/rpc_dart_wasm/.dart_tool/probe/android_main_thread_test.dart`,
on an Android 11 (API 30) emulator.

Measured through a platform-channel round trip sampled every 8 ms, NOT through
frame timings: the Flutter UI thread is separate from the Android main thread,
and an idle test app renders nothing to be janked. `SystemChannels.platform` is
served natively on the platform thread, so its latency IS main-thread
availability.

The busy arm is clearly worse than its own control, so **the byte path does
occupy the main thread.** That much the bench resolves.

## Mechanism

The code fact is certain from reading and not in doubt: `Base64.encodeToString`
per frame under 64 KiB, `Base64.decode` over batches of up to 4 MiB of base64
per drain (`_rpcOutboxBudget`), and an `allocateDirect` + `put` copy per frame,
all on `Dispatchers.Main`.

## After

```
run  state        payload  idle worst  busy worst
2    after fix    4 MiB    17ms        56ms
3    after fix    4 MiB    33ms        28ms
4    after fix    12 MiB   12ms        70ms
5    ABLATED      12 MiB   39ms        38ms
```

**The fix does not move the number.** Run 5 is the ablation — Base64 back on
`Dispatchers.Main` — and the main thread is no less available than with the fix
in place, and better than run 4's fixed 70 ms.

Idle worst ranges 12-39 ms across runs. That noise is the same magnitude as the
effect being looked for, and it is why the bench is marked `broken`: it resolves
*whether* the main thread is occupied and not *by what*, which is exactly what
validating this fix requires.

**The bench was rebuilt once, deliberately and unsuccessfully.** The guest's
outbox hands back at most 4 MiB of base64 per drain, so a 4 MiB response is
roughly one decode; raising the payload to 12 MiB forces four to six drains so
the Base64 cost accumulates. Runs 4 and 5 differ by more than the fix does.

## Canary

Run 5 IS the canary, and it is why this round ships nothing: the fix switched
off in place produced no worse a result than the fix in place. Per the loop's
own rule — *no failing witness, no fix* — the change was **reverted, not
committed**.

## Gate

`melos run analyze:native` PASS swift / PASS kotlin;
`RPC_WASM_DEVICE=emulator-5554 melos run test:wasm:device` `+17 ~2` on every run,
including all four call shapes, the 12 MiB response and cancellation.

Both are reported for completeness, and neither is evidence about the question:
a green suite says the change is harmless, not that it helps.

## Not fixed

All of it, and the negative result is the round's product.

**The item's hypothesis is not supported by measurement.** Base64 of a 64 KiB
frame is well under a millisecond, and the one large decode — the per-drain
batch — was moved and changed nothing. The occupancy is real and comes from
elsewhere, and the remaining candidates cannot simply be moved:
`evaluateJavaScriptAsync` marshalling up to 4 MiB of string across Binder, and
`messenger.send`, which must run on the main thread by contract.

**And the witness criterion cannot be met as written.** The item asks for "a
4 MiB response with no frames >16 ms from the plugin"; on this emulator the IDLE
control alone exceeds 16 ms in most runs, up to 39 ms, with no transfer running.
No fix makes that criterion pass here.

B-41 carries the code fact, all five runs, the fix written out, and the two
things that would resolve it — a physical device, or an in-plugin timer
instrumenting both arms identically.

## Links

Lens `../lenses/RPC-06-native-plugin-layers.md` — `applied:` gains 362; STATUS
unchanged, because an INCONCLUSIVE round confirms nothing.
Bench `../probes/P-53-android-main-thread-during-transfer.md`, new and
`broken`.
Lead `../backlog/archive/B-41-android-base64-on-the-main-thread.md`, new, reason
"bench".
Round `../rounds/357-a-fix-nobody-could-run.md`, the same lens reaching the same
shape of answer from the other side: 357 could not run the code, 362 ran it and
the code disagreed with the hypothesis.
