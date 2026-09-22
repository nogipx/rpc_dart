---
round: 436
commit: 4fa061de
paths: [packages/core/rpc_dart/test/serializers/cbor_test.dart, packages/core/rpc_dart/test/serializers/optimized_cbor_test.dart, packages/core/rpc_dart/test/serializers/fast_cbor_encoder_test.dart, packages/core/rpc_dart/test/serializers/cbor_parity_test.dart, packages/core/rpc_dart/test/audit/audit_header_ascii_test.dart, packages/core/rpc_dart/test/core/error_details_test.dart, packages/transport/rpc_dart_http2/test/grpc_wire_compliance_test.dart, packages/transport/rpc_dart_websocket/test/protocol_close_reason_is_bytes_test.dart, packages/transport/rpc_dart_wasm/test/native_text_is_utf8_test.dart]
scope: [rpc_dart, rpc_dart_http2, rpc_dart_websocket, rpc_dart_wasm]
---

# C-47 — the non-ASCII that must stay

> **Ages from round 435's sha**, deliberately: the transport half was measured
> there and the core half in 436, so the earlier date is the conservative one.

B-30 sweeps non-English prose out of the repo and names one detector:
`grep -rl "[а-яА-Я]" --include="*.dart"`, which it calls "both the detector and
the check". Rounds 435 and 436 found that a share of every hit is not prose at
all but a **fixture**, where the non-ASCII-ness is what the test asserts.

This is the list. A sweep that re-flags one of these has found this note, not a
defect.

## Transports (round 435)

```
rpc_dart_http2/test/grpc_wire_compliance_test.dart:224
    RpcMetadata.forTrailer(2, message: 'Ошибка')
    asserted to percent-encode to ASCII on the wire

rpc_dart_websocket/test/protocol_close_reason_is_bytes_test.dart:41
    ${'кириллица' * 6}
    a close reason is bounded in BYTES, not characters

rpc_dart_wasm/test/native_text_is_utf8_test.dart            4 lines
    UTF-8 round-tripping through the Swift/Kotlin bridge
```

## Core (round 436)

```
test/audit/audit_header_ascii_test.dart:27
    expect(policy.isValidHeaderValue('тест 🚀'), isFalse)
    the policy must REJECT it

test/core/error_details_test.dart:266-277
    test('unicode in reason and metadata')
    'ОШИБКА' / 'тест.v1' / {'ключ': 'значение'} round-tripped

test/serializers/cbor_parity_test.dart:75
    'unicode': 'привет ☺ \u{1F600}'   -- in the parity corpus

test/serializers/cbor_test.dart:132-138
    test('Unicode strings'), the encoding asserted BYTE FOR BYTE:
      'привет' -> 6cd0bfd180d0b8d0b2d0b5d182
      '☺'      -> 63e298ba

test/serializers/cbor_test.dart:374, 404, 421
    'unicode': 'привет мир'

test/serializers/optimized_cbor_test.dart:76
    'strings': ['', 'hello', 'привет', '🌟', 'a' * 1000]

test/serializers/optimized_cbor_test.dart:162-168
    test('Unicode string handling')
      'emoji':    '🚀👨‍💻🌟'      <- a ZWJ sequence, the hard case
      'cyrillic': 'Привет, мир!'
      'chinese':  '你好世界'
      'arabic':   'مرحبا بالعالم'
      'mixed':    'Hello 🌍 Мир 世界'

test/serializers/fast_cbor_encoder_test.dart:48-50, 65-67
    'unicode_short':  'привет'
    'unicode_medium': '🚀' * 50
    'unicode_long':   '世界' * 5000     <- 10,000 chars, 30,000 UTF-8 bytes

test/serializers/fast_cbor_encoder_test.dart:260, 285
    'unicode: 🌟'

test/core/rpc_context_validation_test.dart:76                (round 438)
    RpcContext.withHeaders({'x-name': 'тест с unicode 🚀'})
    then expectLater(..., throwsA(isA<ArgumentError>()))
    the send must REFUSE it; ASCII is valid, so translating inverts the test
```

## Control

Three sites translated the way a sweeper would, one at a time, each reverted
after reading. **They do not all fail the same way, and one does not fail at
all.**

```
site                                 translated to    result
---------------------------------------------------------------------------
cbor_test.dart:138                   '☺'   -> ':)'    FAILS, loudly
    expect(bytesToHex(...), equals('63e298ba'))       the hex no longer matches

audit_header_ascii_test.dart:27      'тест 🚀'        FAILS, loudly
    expect(isValidHeaderValue(x), isFalse)   -> 'test rocket'
                                                      ASCII IS valid, so isFalse
                                                      is now the wrong assertion

optimized_cbor_test.dart:164         'Привет, мир!'   PASSES
    round-trip through encode/decode -> 'Hello, world!'
```

**The third is the dangerous class and the reason this note exists.** A
round-trip fixture asserts `decoded == original`, which holds for any string.
Translate it and the suite stays green while the coverage — does this codec
handle multi-byte UTF-8 — is gone, with nothing anywhere to say so. The two
loud ones would have stopped a careless sweep by themselves; this one would not.

**A fourth shape, found in round 439, and the worst-behaved**: a bulk replace of
comment text is a SUBSTRING replace. `// Регистрируем сервис` appeared four
times, so the sweep batched it — and it is a PREFIX of six longer comments, each
of which became half-translated: `// Register the service. первый раз`. It
compiles, every test passes, `analyze` is clean, and **the only thing that
caught it was the Cyrillic detector re-run, because the surviving tail happened
to be Russian.** Had the tail been ASCII, the damage would have passed the
sweep, the gate and the detector, and been reported as a clean file.

> **Anchor a bulk comment replace to the end of the line, or do the sites one at
> a time.** Identical comments are safe to batch; comments that merely BEGIN the
> same way are not, and nothing distinguishes them when you write the edit.

**The detector for that damage** (round 440), and the only thing that can see
this class:

```
grep -nE '// [A-Za-z][A-Za-z ,.()]*[а-яА-ЯёЁ]'   over tracked *.dart
```

An ASCII sentence followed by non-ASCII on one comment line. Run repo-wide in
440: **no damage** — every hit is a pre-existing Russian sentence containing an
English identifier (`IBlobClient реализация`, `StreamController с onCancel`,
`Premium пользователи`), all in `lib/` or `example/`, which no round has
touched. So round 439's six were the whole population and its repair was
complete.

Its limit is the same one that made 439's escape possible: it sees the damage
only while the surviving tail is non-ASCII. Nothing can see
`// Register the service. v2`.

Round 440 also costed the rule: `replace_all` was used eight times, each checked
first against a `sort | uniq -c` of the file's comment lines, and two were
rejected as prefixes and done singly. The check takes about as long as reading
the comments.

**A third shape, found in round 438 and not among the fixtures above**: prose
data with a producer and an assertion far apart.
`rpc_context_integration_test.dart` built `'Aggregated N элементов [...]'` at
`:592` and asserted `contains('3 элементов')` at `:231` and `:271`. Three sites,
one edit; translate any two and the suite goes red. That is the GOOD failure
mode, and it is worth naming only because a partial edit is what triggers it —
the hazard is proportional to how far the producer sits from the assertion, and
here it was 350 lines. These lines are not fixtures and were translated.

Everything in the census above is one of those two shapes. The round-trip shape
covers `error_details_test.dart:266-277`, `cbor_test.dart:374/404/421`,
`optimized_cbor_test.dart:76` and `:162-168`, and all of
`fast_cbor_encoder_test.dart` — the **majority**.

## Two things this proves about the detector

**It cannot tell prose from data.** Everything above passes `grep -rl`, and
"translate it" is the wrong answer for every line.

**It is script-specific, so it cannot even enumerate the class it keeps
hitting.** `[а-яА-Я]` flags `optimized_cbor_test.dart:167` — because
`'Hello 🌍 Мир 世界'` happens to contain `Мир` — and is blind to `:165`
(`'你好世界'`) and `:166` (`'مرحبا بالعالم'`) two lines above it in the SAME map
literal. It never sees `'世界' * 5000` in the sibling file at all, which is the
largest unicode fixture in the repo.

So a sweeper working from that grep meets these lines one at a time, forever,
with no way to learn there is a class.

## The shape of the split

Not the same in the two places it has been measured:

```
transports   PER FILE   3 of 8 flagged files are pure fixture
core         PER LINE   cbor_test.dart holds both -- comments at :148 and
                        :208 to translate, fixtures at :135 and :374 not
```

A file list can express the first. Nothing but a line list can express the
second, which is why B-30's remaining core work cannot be driven from
`grep -rl` at all.

## What a self-documenting fixture looks like

Nearly all of these already are, and that is why they survived. The key is
named `'unicode'`, `'emoji'`, `'cyrillic'`, `'chinese'`, `'arabic'`; the test is
named `Unicode strings` or `unicode in reason and metadata`. **Adding a Russian
comment to explain a Russian fixture is the one thing that would break this** —
the explanation would itself be a grep hit.

## Verified against a sweep (round 437)

`test/serializers/` was swept down to this list: five files, 85 Cyrillic lines
before, and afterwards **20 non-ASCII lines across the directory, every one of
them named above.** The census missed nothing, and the directory is now a clean
fixture-only state that `grep -P` can confirm in one command.

## Does NOT cover

Non-ASCII outside `test/` — none was found in `lib/` beyond prose, but that was
not the question asked.

Nor the `μ` in `fast_cbor_encoder_test.dart:141` (`$minTimeμs`), which is a unit
suffix in output rather than a fixture, and which parses only because `μ`
terminates a Dart identifier — the same construct round 435 broke and repaired
in the isolate suite. **Round 437 tried to disambiguate it with braces and the
gate refused**: `unnecessary_brace_in_string_interps` under `--fatal-infos`.
The analyzer knows the boundary from the grammar, so it calls the braces
redundant and removes the only signal a reader has. The site carries a comment
saying so; changing the lint config is the owner's call.

`../rounds/435-the-half-that-ships.md`,
`../rounds/436-the-detector-that-cannot-see-its-own-class.md`,
`../backlog/B-30-russian-comments-outside-the-mandate.md`.
