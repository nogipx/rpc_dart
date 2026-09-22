---
round: 438
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is the count, a 13th fixture
  found for C-47, and a second stale comment of the shape round 437 named
commit: yes
---

# Round 438 — the comment that was right once

## Target

**B-30**, core's `rpc_context` family: `rpc_context_test.dart` (83 Cyrillic
lines), `rpc_context_validation_test.dart` (46) and
`rpc_context_integration_test.dart` (41). One subject, three files, 170 lines.

`lib/` remains deferred — the owner has not answered round 436's question and
in-scope work remains. This is the third round taken inside the decided half
while that sits open.

## Hypothesis

Round 437 found one stale comment by translating it, and argued that prose
nobody reads is prose nobody checks. If that is a real mechanism rather than a
single accident, a second sweep of comparable size should turn up another.

## Before

```
rpc_context_test.dart              83
rpc_context_validation_test.dart   46
rpc_context_integration_test.dart  41
```

## Mechanism

Not a behaviour defect. The repo diverging from "English for code, comments,
and logs".

## After

```
                                   before   after
rpc_context_test.dart                  83       0
rpc_context_validation_test.dart       46       1   <- a fixture, see below
rpc_context_integration_test.dart      41       0
```

305 tests pass across `test/core/`.

Repo-wide, tracked `*.dart` Cyrillic:

```
         files   lines
lib         23     316
test        31     801     (was 38 / 1338 before round 435)
example      1      65
```

### A 13th fixture for C-47

`rpc_context_validation_test.dart:76`:

```dart
test('a non-ASCII header value is refused on send', () async {
  final context = RpcContext.withHeaders({'x-name': 'тест с unicode 🚀'});
  await expectLater(..., throwsA(isA<ArgumentError>()));
```

Same shape as `audit_header_ascii_test.dart:27` and one of the two that fail
LOUDLY if translated — ASCII is a valid header value, so the assertion inverts.
Added to C-47.

### A paired-data edit, which the two loud shapes do not cover

`rpc_context_integration_test.dart` had a Russian string on **both sides** of an
assertion: the handler at `:592` returned `'Aggregated N элементов [...]'` and
two tests asserted `contains('3 элементов')` and `contains('2 элементов')`.
Three sites, one edit — translate any two and the suite goes red.

This is a third failure shape for C-47's canary table, between the two it has:

```
asserted encoding   fails loudly, one site
round-trip          passes silently, one site
paired producer/    fails loudly, but only if you find ALL the sites --
  assertion         a partial edit is what breaks it
```

The loud failure is the good case. What makes this one worth naming is that
`grep` on a translated string finds the sites, and `grep` on a *test name* does
not — so the hazard is proportional to how far apart the producer and the
assertion sit. Here it was 350 lines.

## Canary

**The hypothesis held: a second stale comment, in the second file swept.**

`rpc_context_validation_test.dart:178`:

```dart
// Отменяем через 100мс (после начала выполнения)
Timer(Duration(milliseconds: 1), () {
```

100 ms against a 1 ms timer. `git log -S` says the timer WAS
`milliseconds: 100` when the comment was written (`d03962b0`, "implement
context") and became `1` in `6afc2d89`, "update tests". So this is not a comment
that was always wrong — it is a comment that was **right once and drifted**,
which is the more common and less visible case.

That makes two in two rounds:

```
437  fast_cbor_encoder_test.dart:144   "< 3ms" on lessThan(10000) -- 10 ms
438  rpc_context_validation_test.dart  "100мс" on Duration(milliseconds: 1)
```

Both in comments stating a NUMBER, which is the kind a reader can check against
the line below it in one second — if they read it. Neither was caught in the
years these files have existed.

> The rule is usually argued as consistency. The measured effect is that a
> comment in a language the reviewers do not read is exempt from review, and
> drift accumulates there and nowhere else.

The comment now states what the code does, with no note of what it said before
— that belongs in git and in this record, not in the file.

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
test/           801 lines   31 files           in scope, open (21 are C-47)
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Largest remaining: `rpc_responder_endpoint_test.dart` (116),
`rpc_message_parser_test.dart` (53), `call_processor_test.dart` (40).

**Two stale comments in two rounds is now a rate, not an anecdote**, and it
bears on the deferred half: the 277 `lib/` comment lines have had the same
exemption from review, on code that ships. Nobody has counted how many of them
are wrong. That is not an argument for taking them ahead of the owner's order —
it is a number the owner does not have yet, and now does.

## Links

- B-30 — the `rpc_context` family done
- C-47 — a 13th site added; a third failure shape named for its canary table
- RPC-23 — the stale-comment mechanism, now with two instances
