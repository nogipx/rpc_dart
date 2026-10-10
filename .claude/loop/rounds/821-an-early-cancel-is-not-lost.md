---
round: 821
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http]
lens: RPC-20
bench: P-304 — new
commit: yes
severity: S2
release: none
---

# Round 821 — an early cancel is not lost

## Target

RPC-20, the top-ranked lens, last applied in round 759. Round 806's http
cancel witness flaked under load with the cancel landing before the
handler had started, and was changed to wait for the handler. That change
left the early window untested: a cancel that reaches the pipeline before
dispatch, while the call's context (and so its token) does not exist yet.
`_handleClientCancellation` cancels `state.cachedContext?.cancellationToken`
only.

## Hypothesis

A cancel arriving before dispatch finds no token, tears the stream down,
and the handler then starts with a token that never fires and runs to
completion (I-6).

## Before

```
P-304 control (no cancel): channel 40/40 completed, http 20/20 completed
```

## Mechanism

n/a (CLEAN).

## After

```
  transport  delay      entered  saw cancel  completed
  channel    1-50 ms    40       40          0
  http       1 ms       0        0           0
  http       3 ms       17       17          0
  http       10-500 ms  19-20    all         0
```

## Canary

The first http run, with a 1 s handler, read every cancel as lost. That was
macOS's ~2.1 s delay in seeing a peer's close (P-295), longer than the
handler; at 5 s the same calls all see the cancel. The bench is shaped so
that the OS's delay cannot decide a row.

## The verdict questions

1. Only the cancel's delay differs.
2. Yes against the control: completed 40 -> 0.
3. In the server's handler: whether its token fired.
4. Six delays, 20-40 calls each.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. The 1 s http result was explained, not dismissed: P-295's delay.
9. none.
10. No code changed.
A1. Defaults. A2. Latency (the cancel's delay) is the variable.
L1. n/a.

## Gate

No code changed; the probe is outside the tree (`.dart_tool/probe`).

## Siblings

No code changed. websocket, isolate and wasm reach the same pipeline path
(`x-client-cancelled`) as the channel; not measured separately.

## Not fixed

none.

## Links

Lens `../lenses/RPC-20-the-window-before-the-first-listener.md`. Bench
`../probes/P-304-a-cancel-in-the-first-milliseconds.md`. Negative
`../checked/C-77-a-cancel-before-dispatch-still-reaches-the-handler.md`.
