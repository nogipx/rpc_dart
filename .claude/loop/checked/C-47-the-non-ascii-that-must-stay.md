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

## Does NOT cover

Non-ASCII outside `test/` — none was found in `lib/` beyond prose, but that was
not the question asked. Nor the `μ` in `fast_cbor_encoder_test.dart:140`
(`$minTimeμs`), which is a unit suffix in output rather than a fixture, and
which parses only because `μ` terminates a Dart identifier — the same construct
round 435 broke and repaired in the isolate suite.

`../rounds/435-the-half-that-ships.md`,
`../rounds/436-the-detector-that-cannot-see-its-own-class.md`,
`../backlog/B-30-russian-comments-outside-the-mandate.md`.
