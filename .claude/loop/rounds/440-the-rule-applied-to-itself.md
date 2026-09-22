---
round: 440
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is the count, plus a repo-wide
  sweep for the damage pattern round 439 introduced
commit: yes
---

# Round 440 — the rule applied to itself

## Target

**B-30**, core's `test/streams/`: six files, 171 Cyrillic lines.

```
call_processor_test.dart        40
server_stream_test.dart         36
stream_processor_test.dart      28
bidirectional_stream_test.dart  24
unary_test.dart                 22
client_stream_test.dart         21
```

`lib/` remains deferred — fifth round inside the decided half, the owner's
question from 436 still open.

## Hypothesis

Round 439 injected six half-translated comments with a careless `replace_all`
and wrote the rule: **anchor a bulk comment replace to the end of the line, or
do the sites one at a time.** This round is the first to work under it. Two
things to establish: that following it costs little, and that 439's damage was
confined to what that round repaired.

## Before

```
test/streams/   171 Cyrillic lines across 6 files
```

## Mechanism

Not a behaviour defect. The repo diverging from "English for code, comments,
and logs".

## After

```
test/streams/   0 Cyrillic, 0 emoji across 6 files
```

226 tests pass (one pre-existing skip).

Repo-wide, tracked `*.dart` Cyrillic:

```
         files   lines
lib         23     316
test        21     443     (was 38 / 1338 before round 435)
example      1      65
```

`test/` is now a third of what it was five rounds ago.

### Following 439's rule, in practice

`replace_all` was used eight times and **each one checked first for a prefix
relationship against every other comment in the file**. Two were rejected on
that check and done singly:

```
// Проверяем наблюдаемое поведение        IS a prefix of five longer comments
// Отменяем все вызовы метода             two indentations, both real
```

The check is a `sort | uniq -c` over the file's comment lines and takes about
as long as reading them. The cost of the rule is negligible; the cost of not
having it was six defects nothing in the gate could see.

## Canary

**The damage pattern from 439 was swept for repo-wide, not just in the files
that round touched.** A half-translated comment has a signature — an ASCII
sentence followed by Cyrillic on the same comment line:

```
grep -nE '// [A-Za-z][A-Za-z ,.()]*[а-яА-ЯёЁ]'   over all tracked *.dart
```

It returns **no damage**. Every hit is a pre-existing Russian sentence that
happens to contain an English identifier — `IBlobClient реализация`,
`StreamController с onCancel`, `Premium пользователи` — and all of them sit in
`lib/` or `example/`, which no round has touched. So 439's six were the whole
population, and its repair was complete.

That detector is worth keeping: it is the only thing that can see this class,
and it costs one grep. Recorded in C-47.

The limit remains what 439 stated — this catches the damage only while the
surviving tail is non-ASCII. Nothing can see
`// Register the service. v2`.

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
test/           443 lines   21 files           in scope, open (21 are C-47)
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Of the 443 remaining `test/` lines, **21 are the C-47 fixtures that never go
away**, so the real remainder is 422 across roughly 18 files. Largest:
`rpc_message_parser_test.dart` (53),
`in_memory_transport_streams_test.dart` (31),
`rpc_stream_id_manager_test.dart` (30), `rpc_metadata_test.dart` (20),
`rpc_message_frame_test.dart` (20), `rpc_message_test.dart` (18).

No stale number-comment found in 171 lines, consistent with 439 and against
437/438. Three rounds at 0, two at 1 — the earlier pair stand, the rate does
not generalise.

## Links

- B-30 — `test/streams/` done; `test/` down to a third of round 435's figure
- C-47 — the prefix-damage detector added, with its repo-wide result
- RPC-23 — 439's rule, now applied once and costed
