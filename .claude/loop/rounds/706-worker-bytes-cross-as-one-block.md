---
round: 706
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-07
bench: none — a Chrome probe, 20 unary calls of 1 MiB host-to-worker, three rounds, dart2js and dart2wasm (`.dart_tool/probe/zz_bytes_bench_test.dart.txt`, `zz_bytes_bench_w_test.dart.txt`)
commit: yes
release: changelog
---

# Round 706 — worker bytes cross as one block

## Target

B-160: on the web, `serializeBytes` turned a payload into `List<int>`, which
crossed to the worker as a JS array of numbers -- boxed and copied element by
element on both sides -- and `materializeBytes` mapped it back.

## Hypothesis

Throughput is dominated by that per-byte work; a typed array, which structured
clone copies as one block, removes it.

## Before

The echo worker gained a `Size` method; 1 MiB string requests:

```
dart2js host + worker      8.0, 7.5, 7.5 MiB/s
dart2wasm host + worker    2.9, 2.9, 2.9 MiB/s
```

## Mechanism

As hypothesised.

## Fix

`serializeBytes` returns the `Uint8List` itself; a view into a larger buffer
is compacted first, because cloning a typed array clones its whole underlying
buffer. `materializeBytes` already accepted a `Uint8List` and still reads the
list form from an older peer. A VM test pins both.

## After

```
dart2js host + worker      272.1, 285.3, 299.4 MiB/s   (about 36x)
dart2wasm host + worker     64.1,  65.8,  65.9 MiB/s   (about 22x)
```

On dart2wasm the worker reports the exact size, `1048576`. Every Chrome worker
test passes.

## Canary

Before is the canary: the same probe with the change stashed, on both
compilers.

## The verdict questions

1. Yes: Before on the same tree.
2. Yes: the MB/s the lead asked for.
3. Yes: throughput, and the payload arriving intact.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a trade: nothing gets slower.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, `test:web` (0 failures).

## Not fixed

Transferring the buffer instead of cloning it would save the one remaining
copy, but leaves the sender's array detached; not done.

## Links

Lead `../backlog/B-160-isolate-web-bytes-travel-as-js-arrays.md` closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` -- `applied: [..., 706]`.
