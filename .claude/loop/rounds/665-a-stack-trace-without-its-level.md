---
round: 665
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — the witness test drives the bridge's console channel exactly as the plugins send it
commit: yes
release: changelog
---

# Round 665 — a stack trace without its level

## Target

B-170, triaged in this session as reachable on every guest error: the guest
zone handler (`rpc_wasm.dart`) logs `error\nstack`, and Android joins console
entries with `\n`. Scope: the one place console text becomes lines,
`RpcFlutterWasmBridge`'s console handler; the two native shims only prefix.

## Hypothesis

The bridge splits on `\n`, so only an entry's first line keeps its `E:`.

## Before

```
sent 'E:Unhandled error: boom\n#0 main\n#1 run'
  got ['E:Unhandled error: boom', '#0 main', '#1 run']
sent 'E:boom\n#0 main\nI:next\nW:careful'
  got ['E:boom', '#0 main', 'I:next', 'W:careful']
```

Witness: `packages/transport/rpc_dart_wasm/test/a_console_line_keeps_its_level_test.dart`.

## Mechanism

Both shims prefix an entry once (`'E:' + args.join(' ')`; iOS
`"\(prefix):\(msg)"`), and an entry's text may contain `\n`. The bridge emitted
each line as it was.

## After

```
  got ['E:Unhandled error: boom', 'E:#0 main', 'E:#1 run']
  got ['E:boom', 'E:#0 main', 'I:next', 'W:careful']
```

A line that starts with a level prefix sets the level; any other line carries
the level of the entry it continues.

## Canary

The handler without the carry is the tree before the fix: both witnesses failed
with `Expected: [..., 'E:#0 main', ...] Actual: [..., '#0 main', ...] Which: at
location [1] is '#0 main' instead of 'E:#0 main'`. The GUARD (single-line
entries unchanged) and the existing ASCII/UTF-8 console tests green both ways.

## Gate

`test:wasm` +47; wasm `analyze` clean; workspace `analyze` green and `test:unit`
green in 15 packages (unaffected, run for the record); `format` clean.

## Committed later

The session that ran this round left it uncommitted. Verified again at commit
time by the session running rounds 666-674, on the owner's instruction: the
witness green, the canary red with the same two messages quoted above, and
`test:wasm` +47, `analyze` and `format:check` (wasm included) green.

## Not fixed

A continuation line that itself begins with `E:` (or `I:`, `W:`, `D:`) is read as
a new entry -- the Android join leaves nothing else to split on. Fixing that
needs a native change and a device run.

## Links

Lead `../backlog/B-170-wasm-console-lines-lose-their-level.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 665]`.
