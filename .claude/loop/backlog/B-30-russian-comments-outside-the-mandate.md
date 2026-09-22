---
status: decided by owner (round 415)
round: 303
commit: 139bca2a
paths: [packages/core/*/test/**, packages/core/*/example/**, packages/transport/*/test/**, packages/transport/*/example/**, packages/data/rpc_data/lib/**, packages/data/rpc_data_sqlite/lib/**, packages/blob/rpc_blob/lib/**, packages/notify/rpc_notify/lib/**]
probe: none
reason: decided — sweep the 47 test/ and example/ files inside core+transport first; the 23 lib/ files are all outside the mandate and wait
---

# B-30 — Russian comments in packages outside the mandate

The root `CLAUDE.md` states the rule plainly:

> ## Style
> - English for code, comments, and logs.

Round 303 found `rpc_http2_server.dart` written in Russian throughout — class
doc, constructor doc, every log string — and fixed it as part of the http2
sweep. The check that confirmed the file was clean afterwards found the same
thing in **25 lib files**, and only three of them are in the mandate.

Measured with `grep -rlE "[А-Яа-яЁё]" packages/*/*/lib`, after round 303:

    packages/data/rpc_data/lib/            16 files
    packages/blob/rpc_blob/lib/             3 files
    packages/data/rpc_data_sqlite/lib/      3 files
    packages/notify/rpc_notify/lib/         1 file
    packages/transport/rpc_dart_http2/lib/  2 files   <- round 304 covers these

`rpc_data` is the worst: the Cyrillic is in `models.dart`, `data_contract.dart`,
the repository interfaces and the client — the API surface a user of that
package reads first. One of the 16 is `data_contract.g.dart`, which is
GENERATED, so fixing that one means fixing the generator's template or the
source contract, not the file.

## Why this is a real defect and not a preference

It is the project's own written rule, so this is rule one applied to prose: the
implementation (the repo's stated style) and the code diverge. And it is not
cosmetic on a PUBLISHED package — all 22 are on pub.dev, so these doc comments
are what dartdoc renders on the package page for an audience the rule says is
English-speaking.

## Why round 303 did not do it

The owner's mandate is five packages in a stated order, and these are none of
them. Sweeping four unrelated packages mid-mandate would be the round choosing
its own scope; `rpc_data` alone is 16 files and would be a round of its own.

## What it would cost

One round per package, probably two for `rpc_data`. Mechanical but not
automatic: the log strings are user-visible output, and a few of the comments
are the only description of the behaviour they sit on, so they need translating
rather than deleting. `grep -rlE "[А-Яа-яЁё]"` is the detector and the check.

The generated file needs its source found first — that is the only part that is
not a straight edit.

## Owner decision

**Taken: sweep the in-scope half first — the 47 `test/` and `example/` files in
core and transport. The 23 `lib/` files wait.**

Re-counted by hand in the backlog review, because both earlier numbers in this
record had drifted:

```
lib/                       23   data/rpc_data 16, data/rpc_data_sqlite 3,
                                blob/rpc_blob 3, notify/rpc_notify 1
test/ + example/           47   core and transport
```

Two things that changes. **The three http2 files this record named are gone** —
swept incidentally by rounds working in that package, so the `lib/` half is now
entirely OUTSIDE the mandate. And the in-scope half is the larger one: 47
against 23.

`grep -rl "[а-яА-Я]" --include="*.dart"` is both the detector and the check.
Translate rather than delete — several of these comments are the only
description of the behaviour they sit on.

The `lib/` remainder keeps its own reason and is not closed: 16 of its files are
`rpc_data`'s `models.dart`, contract and repository interfaces, which is a
PUBLISHED API surface that dartdoc renders. One is generated, so that one means
finding the generator's source first.

## Round 432 — the example half is done, and the real number is LINES

**47 files is 1817 Cyrillic lines.** The recount above fixed the file count and
still measured the wrong thing: translating properly — which this record itself
demands, *"translate rather than delete"* — is per line, and 1817 is not one
round's work. Saying so before starting is what L-12 is for.

```
                            before   after
example/, core + transport   529      0     10 files, round 432
test/, core + transport     1288   1288     37 files, open
```

The examples went first because `example/` is published to pub.dev and is the
first thing a reader evaluating the package meets; test comments are internal.
Emoji were removed in the same pass, including from the text these programs
PRINT, which is output rather than source.

**What the test half needs that the examples did not**: several of the 1288
lines are test NAMES, and renaming one changes what the suite reports. That is
a different kind of edit from a comment and is worth deciding deliberately.

## Round 435 — the transport tests, and a third axis

Five files done. Transports go from 8 tracked Cyrillic test files to 3, and the
three that remain **must keep theirs**:

    rpc_dart_http2/test/grpc_wire_compliance_test.dart:224      'Ошибка'
    rpc_dart_websocket/test/protocol_close_reason_is_bytes_test.dart:41
    rpc_dart_wasm/test/native_text_is_utf8_test.dart            4 lines

Percent-encoding to ASCII, a close reason measured in BYTES not characters, and
UTF-8 round-tripping through the native bridge. In all three the non-ASCII-ness
IS the subject. **So the grep is not "both the detector and the check"** — the
check it prescribes would demand breaking three tests.

Nor is it correctly scoped: run over paths rather than `git ls-files`, it also
returns 10 gitignored Android resource-merge artifacts under
`rpc_dart_wasm/example/build/`, in nine languages nobody in this repo wrote.

Test NAMES were renamed after all, and the suites re-RUN (25 + 6 pass). The
snake_case Cyrillic names were not readable behaviour descriptions in any
language, and a suite name is internal output, not an API.

### The recount — comment and log are different axes

Counted over tracked `*.dart` only:

                     files   Cyrillic lines
        lib             23        316
        test            38       1338
        example          1         65

`lib/` is still 23 files, but this record's reason for deferring it names the
wrong ones. The weight is in a file it does not mention:

    packages/notify/rpc_notify/lib/src/stream_distributor.dart   176 lines

More than any test file in the repo, and **39 of those 176 are runtime log
messages** — `_logger.warning('Попытка публикации в закрытый дистрибьютор')` and
37 more. The other 137 are comments.

    comment   read by whoever opens the source, or by dartdoc
    log       EMITTED into the user's own log stream at runtime

A user can avoid the comments. They cannot avoid the logs without turning the
logger off. `CLAUDE.md` names all three — "code, comments, and logs" — and this
record has only ever counted the first two.

Emoji, on the same axis, do not reach `lib/` at all: 154 lines across 14 files,
all `test/` plus one `example/`.

### What remains

    lib/ logs        39 lines   rpc_notify only        runtime, user-visible
    lib/ comments   277 lines   23 files               dartdoc / maintainers
    test/          1338 lines   38 files, core mostly  internal
    generated        21 lines   rpc_data/*.g.dart      fix the SOURCE first

The generated 21 are in `data_contract.g.dart`, from `data_contract.dart` (23
lines, same directory). Fix the source, regenerate.

**The 39 log lines are the slice to take next** — smallest, and the only one a
user meets without opening a file. **Round 436 did NOT take them**: this
record's owner decision is an ORDER, in-scope work remains, and reversing it is
the owner's call rather than a round's. It is put to them, not acted on.

## Round 436 — the detector cannot enumerate its own exceptions

`test/zero_copy/` swept: 3 files, 171 Cyrillic + 98 emoji to zero. That takes
the repo's remaining emoji from 154 lines to 56 — all 98 were decoration.

Every deliberate non-ASCII fixture in the repo is now listed in
`../checked/C-47-the-non-ascii-that-must-stay.md`, 12 sites. Two consequences
for this record's plan.

**The detector cannot tell prose from data.** `cbor_test.dart` pins `'привет'`
and `'☺'` to their exact byte encodings (`6cd0bfd180d0b8d0b2d0b5d182`,
`63e298ba`); translating the string changes the expected hex.

**The detector is script-specific, so it cannot enumerate the class it keeps
hitting.** `[а-яА-Я]` flags `optimized_cbor_test.dart:167` only because
`'Hello 🌍 Мир 世界'` happens to contain `Мир`, and is blind to `'你好世界'` and
`'مرحبا بالعالم'` two lines above it in the SAME map literal, and to
`'世界' * 5000` in the sibling file — 10,000 characters, the largest unicode
fixture here.

**And the split changes SHAPE between packages:**

```
transports   PER FILE   3 of 8 flagged files are pure fixture
core         PER LINE   cbor_test.dart holds comments to translate at
                        :148 and :208, fixtures not to at :135 and :374
```

A file list expresses the first. **Nothing but a line list expresses the
second**, so the remaining 26 core test files cannot be driven from `grep -rl`.

### What remains

```
lib/ logs        39 lines   rpc_notify only    deferred by the owner's ORDER
lib/ comments   277 lines   23 files           same
test/          1069 lines   26 core files      in scope, open
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

`cbor_test.dart`, `optimized_cbor_test.dart` and `fast_cbor_encoder_test.dart`
are the three that mix both kinds — read C-47 before touching them.

## Round 437 — the serializers, and the comment nobody checked

`test/serializers/` swept, 85 Cyrillic lines to 10. Counting every script the
directory now holds **20 non-ASCII lines and every one is in C-47** — the
census held exactly, which is what made these five files sweepable at all.

**The rule's non-style argument, found by obeying it.**
`fast_cbor_encoder_test.dart:144` read

```dart
expect(avgTime, lessThan(10000)); // < 3ms среднее время
```

10,000 microseconds is 10 ms. The comment had been wrong since it was written,
and survived because a reviewer who skips a language they do not read skips the
claim inside it too. The sibling comment one line down was correct.

**And the repo's lint mandates a construct that has already caused one
mis-edit.** `$minTimeμs` reads as one identifier and is not; `${minTime}μs`
would say so and `unnecessary_brace_in_string_interps` refuses it under
`--fatal-infos`. Commented in place. The config is the owner's call.

### What remains

```
lib/ logs        39 lines   rpc_notify only    deferred by the owner's ORDER
lib/ comments   277 lines   23 files           same
test/           970 lines   33 files           in scope, open (20 are C-47)
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Largest files left: `rpc_responder_endpoint_test.dart` (116),
`rpc_context_test.dart` (83).

## Round 438 — the `rpc_context` family, and a second stale comment

170 Cyrillic lines to 1 across the three `rpc_context` test files; the one that
stays is a new C-47 fixture (`'тест с unicode 🚀'`, asserted to throw
`ArgumentError`). 305 tests pass in `test/core/`.

**437's finding is now a rate.** A second stale comment, in the second file
swept: `// Отменяем через 100мс` over `Timer(Duration(milliseconds: 1))`. And
`git log -S` shows the timer WAS 100 ms when the comment was written — so it was
right once and drifted, which is the harder case to see than one that was always
wrong.

```
437  fast_cbor_encoder_test.dart:144    "< 3ms"  on lessThan(10000)
438  rpc_context_validation_test.dart   "100мс"  on milliseconds: 1
```

**This bears on the deferred half.** The 277 `lib/` comment lines have had the
same exemption from review, on code that ships and that dartdoc renders. Nobody
has counted how many of them are wrong. Not an argument for jumping the owner's
order — a number the owner did not have.

### What remains

```
lib/ logs        39 lines   rpc_notify only    deferred by the owner's ORDER
lib/ comments   277 lines   23 files           same
test/           801 lines   31 files           in scope, open (21 are C-47)
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Largest left: `rpc_responder_endpoint_test.dart` (116),
`rpc_message_parser_test.dart` (53), `call_processor_test.dart` (40).
