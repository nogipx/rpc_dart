---
round: 435
verdict: FIXED
packages: [rpc_dart_isolate, rpc_dart_http2]
lens: RPC-23
bench: none — a translation sweep; the evidence is a count taken on three axes
  the lead had not separated, plus the gate
commit: yes
---

# Round 435 — the half that ships

## Target

**B-30**, continued: the `test/` half the lead left open after round 432 did
`example/`. Scoped to the TRANSPORT packages — 8 tracked test files with
Cyrillic — because core's 29 files are a round of their own and L-12 says state
the scope before starting.

## Hypothesis

n/a for the defect, which is not in dispute. What needed measuring was where
the remaining weight actually sits, because the lead's reason for deferring
`lib/` names files by package and never by what reads them.

## Before

```
tracked transport test files with Cyrillic        8

tracked *.dart, Cyrillic lines      files   lines
  lib                                 23     316
  test                                38    1338
  example                              1      65
```

## Mechanism

Not a behaviour defect. `CLAUDE.md` says "English for code, comments, and
logs", and the repo diverges from its own stated rule.

The part that needed thought is that this population is not homogeneous. It
splits by **who reads it**, and the three groups are not interchangeable:

```
comment in test/   a maintainer who opened the file
comment in lib/    that, plus dartdoc on the pub.dev package page
LOG in lib/        emitted at runtime into the user's own log stream
```

The third is the one a reader cannot avoid. No file needs opening, and turning
it off means turning the logger off.

## After

```
tracked transport test files with Cyrillic        3   (all three must keep it)
```

Five files translated:

```
rpc_dart_isolate/test/isolate_zero_copy_demo_test.dart
rpc_dart_isolate/test/isolate_crash_isolation_test.dart
rpc_dart_isolate/test/isolate_verification_test.dart
rpc_dart_isolate/test/isolate_transport_test.dart
rpc_dart_http2/test/http2_rpc_integration_test.dart
```

Test NAMES were renamed, which the lead flagged as "a different kind of edit"
because it changes what the suite reports. Done deliberately: the snake_case
Cyrillic names (`создает_уникальные_stream_id`) were not readable behaviour
descriptions in any language, and a suite name is internal output, not an API.
31 tests pass under the new names.

**The three that must NOT be translated:**

```
rpc_dart_http2/test/grpc_wire_compliance_test.dart:224      'Ошибка'
    asserted to percent-encode to ASCII on the wire
rpc_dart_websocket/test/protocol_close_reason_is_bytes_test.dart:41
    ${'кириллица' * 6} — the subject is BYTES, not characters
rpc_dart_wasm/test/native_text_is_utf8_test.dart            4 lines
    the subject is UTF-8 round-tripping through the native bridge
```

In all three the non-ASCII-ness IS the subject. B-30 calls its grep "both the
detector and the check"; that check would demand breaking three tests.

Nor is the grep correctly scoped. Run over paths rather than `git ls-files`, it
also returns **10 gitignored Android resource-merge artifacts** under
`rpc_dart_wasm/example/build/`, in Belarusian, Bulgarian, Kazakh, Kyrgyz,
Macedonian, Mongolian, Russian, Serbian and Ukrainian.

**The recount.** The lead defers `lib/` because "16 of its files are
`rpc_data`'s models, contract and repository interfaces, which is a PUBLISHED
API surface that dartdoc renders". The weight is in a file it never names:

```
packages/notify/rpc_notify/lib/src/stream_distributor.dart   176 lines
    137 comments
     39 RUNTIME LOG MESSAGES
```

More Cyrillic than any test file in the repo, and the 39 are
`_logger.warning('Попытка публикации в закрытый дистрибьютор')` and 37 like it.

Emoji, counted the same way, have a different distribution entirely: 154 lines
across 14 files, every one `test/` or `example/`, **none in `lib/`**. Two style
rules stated in one sentence, two populations, and only one of them reached
shipped code.

One substantive edit beyond translation. The timing print used
`$zeroCopyTimeμs` — `μ` is not an identifier character in Dart, so it parsed as
`$zeroCopyTime` then a literal `μs`. Translating to `$zeroCopyTimeus` made one
undefined identifier; it is `${zeroCopyTime}us`.

Also removed: `rpc_dart_isolate/test/b31_import_probe_test.dart`, round 428's
probe placeholder, whose own header marks it `SAFE TO DELETE`.

## Canary

None applicable — a translation changes no behaviour, so there is nothing to
switch off. Two things stand in for it.

The two largest files were **RUN**, not merely analysed:

```
isolate_transport_test.dart      25 tests pass under renamed names
http2_rpc_integration_test.dart   6 tests pass
```

And the `μ` bug is the round's own evidence that reading is not enough. It
passes grep, it passes review, and it fails `dart analyze`. Caught by the gate,
not by care.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS (after one fixup — see below)
melos run license:check  compliant, 1609/1609
```

`format:check` failed once, on `isolate_zero_copy_demo_test.dart` — a file
rewritten earlier in this round and formatted then, re-edited afterwards, and
not re-formatted. Formatting is a property of the last edit to a file, not of
the file.

## Not fixed

B-30 does not close. What remains, on the axis this round introduced:

```
lib/ logs        39 lines   rpc_notify only        runtime, user-visible
lib/ comments   277 lines   23 files               dartdoc / maintainers
test/          1338 lines   38 files, core mostly  internal
generated        21 lines   rpc_data/*.g.dart      fix the SOURCE first
```

**The 39 log lines are the slice to take next** — smallest, and the only one a
user meets without opening a file.

The 21 generated lines are in `packages/data/rpc_data/lib/src/rpc/
data_contract.g.dart` and cannot be hand-edited. They come from
`data_contract.dart` (23 lines, same directory): fix the source, regenerate.

## Links

- B-30 — transport test half done; `lib/` logs identified as the next slice
- L-12 — second instance of "a count is taken on an AXIS". Here the axis is
  AUDIENCE, and the lead had counted two of three categories
- RPC-23 — the narrative beside the code; extended with the fixture-versus-
  prose problem a text detector cannot solve
