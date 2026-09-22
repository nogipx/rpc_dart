---
round: 439
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is the count, and a self-
  inflicted defect the round's own detector caught
commit: yes
---

# Round 439 — the replace that matched a prefix

## Target

**B-30**, core's `test/endpoint/`: `rpc_responder_endpoint_test.dart` (116
Cyrillic lines, the largest remaining file in the repo),
`rpc_caller_endpoint_cancellation_test.dart` (37),
`rpc_caller_endpoint_test.dart` (32), `rpc_endpoint_ping_test.dart` (2).

`lib/` remains deferred — fourth round inside the decided half with the owner's
question open.

## Hypothesis

None about the code. The method question, after 437 and 438 both found stale
number-comments: do they keep coming? Here, **no** — 187 lines translated and
not one number-comment disagreed with its code.

## Before

```
rpc_responder_endpoint_test.dart              116
rpc_caller_endpoint_cancellation_test.dart     37
rpc_caller_endpoint_test.dart                  32
rpc_endpoint_ping_test.dart                     2
```

## Mechanism

Not a behaviour defect. The repo diverging from "English for code, comments,
and logs".

## After

```
test/endpoint/    0 Cyrillic, 0 emoji across 51 files
```

Every test in the directory passes.

Repo-wide, tracked `*.dart` Cyrillic:

```
         files   lines
lib         23     316
test        27     614     (was 38 / 1338 before round 435)
example      1      65
```

## Canary

**The round injected a defect and its own detector caught it.** That is the
finding, and it was not planned.

`rpc_responder_endpoint_test.dart` had `// Регистрируем сервис` four times, so
the sweep used a `replace_all`. **`replace_all` is a SUBSTRING replace, not a
line replace**, and that comment is a prefix of six longer ones. The result:

```
// Регистрируем сервис первый раз          -> // Register the service. первый раз
// Регистрируем сервис но НЕ запускаем ...  -> // Register the service. но НЕ ...
// Регистрируем сервис ПОСЛЕ start()        -> // Register the service. ПОСЛЕ start()
// Разрегистрируем сервис - теперь ...      -> // Unregister the service. - теперь ...
```

Six sites, each now a sentence in two languages with a full stop in the middle.

**It compiles. Every test passes. `melos run analyze` is clean.** Nothing in
the gate can see a mangled comment. What caught it was the round's own
`grep -P '[а-яА-ЯёЁ]'` re-run, because the surviving tail happened to be
Russian.

> **Had the tail been ASCII — `// Регистрируем сервис v2`, say — the damage
> would have survived the sweep, the gate, and the detector, and been reported
> as a clean file.**

So this is a new failure mode for C-47's table, and it is the worst-behaved one
yet:

```
asserted encoding    fails loudly
paired producer/     fails loudly, if a PARTIAL edit
round-trip fixture   passes silently, detector still flags it
prefix over-match    passes silently, detector flags it ONLY BY LUCK
```

The rule that follows is specific and cheap: **a bulk replace of comment text
must anchor to the end of the line**, or be done one site at a time. The four
identical sites were worth batching; the six that merely began the same way were
not, and nothing distinguished them at the point of writing the edit.

All six repaired by hand, and the directory re-read afterwards.

Second, smaller slip, recorded because it cost two commands: a `cd` inside a
compound shell command **persisted**, and the next three `grep`s reported "No
such file or directory" against paths that exist. The tool's working directory
survives between calls; the repo's own guidance says to prefer absolute paths.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

## Not fixed

```
lib/ logs        39 lines   rpc_notify only    deferred by the owner's ORDER
lib/ comments   277 lines   23 files           same
test/           614 lines   27 files           in scope, open (21 are C-47)
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Largest remaining: `rpc_message_parser_test.dart` (53),
`call_processor_test.dart` (40), `server_stream_test.dart` (36),
`in_memory_transport_streams_test.dart` (31).

The stale-comment rate did NOT continue here: 187 lines, zero disagreements.
Two in two rounds then zero in one says the earlier pair were real and the rate
is not uniform — not that it has stopped. It bears watching rather than
quoting.

## Links

- B-30 — `test/endpoint/` done; `test/` now under half what it was at round 435
- C-47 — a fourth failure shape, the one a detector catches only by luck
- RPC-23 — extended with the prefix-over-match rule
