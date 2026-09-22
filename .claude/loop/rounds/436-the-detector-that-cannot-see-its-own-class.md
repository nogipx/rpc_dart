---
round: 436
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is a census of the fixture
  class the lead's detector cannot enumerate, plus the gate
commit: yes
---

# Round 436 — the detector that cannot see its own class

## Target

**B-30**, continued into core. Round 435 did the transport `test/` half and
ended by recommending the `lib/` logs; those stay deferred, because the owner's
decision (round 415) is an ORDER — in-scope `test/`+`example/` first, `lib/`
waits — and in-scope work remains. Taking `lib/` now would be the round
choosing its own scope, which is what round 303 refused to do. The recommendation
is put to the owner instead, not acted on.

Slice: **`test/zero_copy/`** — one directory, three files, and the densest
emoji concentration in the repo.

## Hypothesis

Round 435 found that 3 of 8 flagged transport test files were fixtures rather
than prose. If that is a class and not an accident, core should hold more of
them — and core is where the serializer tests live, which exist to encode text.

## Before

```
core test files with Cyrillic or emoji      29 files

test/zero_copy/          171 Cyrillic + 98 emoji across 3 files
                         98 of the repo's 154 remaining emoji lines
```

## Mechanism

Not a behaviour defect — the repo diverging from its own stated rule, "English
for code, comments, and logs".

The part worth measuring is which hits are prose at all.

## After

```
test/zero_copy/           0 Cyrillic, 0 emoji across 6 files
repo emoji lines        154 -> 56
```

Three files rewritten: `zero_copy_endpoint_test.dart`,
`zero_copy_streams_test.dart`, `zero_copy_endpoint_streams_test.dart`. Every
one of their 98 emoji was decoration — in a test name, a comment, or a `print`.
29 tests pass.

### The census, and what it says about the detector

Every deliberate non-ASCII fixture in the repo is now listed in
`../checked/C-47-the-non-ascii-that-must-stay.md`. Two findings came out of
building it.

**The split is per LINE in core, not per file.** In transports it was per file
— 3 of 8 were pure fixture. `cbor_test.dart` holds both kinds:

```
:135  bytesToHex(CborCodec.encodeUnsafe('привет'))   FIXTURE
:138  expect(bytesToHex(...('☺')), equals('63e298ba')) FIXTURE
:148  expect(encoded[1], equals(24));  // длина 24     PROSE
:208  expect(encoded[1], equals(100)); // длина 100    PROSE
:374  'unicode': 'привет мир'                          FIXTURE
```

The encodings are asserted byte for byte, so changing the string changes the
expected hex. A file list can express "3 of 8 files"; nothing but a line list
can express this, and B-30's detector is `grep -rl`.

**The detector is script-specific, so it cannot enumerate the class it keeps
hitting.** `[а-яА-Я]` flags `optimized_cbor_test.dart:167` — only because
`'Hello 🌍 Мир 世界'` happens to contain `Мир` — and is blind to two lines
directly above it in the SAME map literal:

```
:163  'emoji':    '🚀👨‍💻🌟'          ZWJ sequence, the hard case
:164  'cyrillic': 'Привет, мир!'      <- the only one the grep sees
:165  'chinese':  '你好世界'            invisible
:166  'arabic':   'مرحبا بالعالم'      invisible
:167  'mixed':    'Hello 🌍 Мир 世界'   <- seen, by accident
```

And it never sees `fast_cbor_encoder_test.dart:50`, `'世界' * 5000` — 10,000
characters, 30,000 UTF-8 bytes, the **largest unicode fixture in the repo**.

So a sweeper working from that grep meets these one at a time, forever, with no
way to learn there is a class. That is what C-47 is for.

## Canary

Three fixture sites were translated the way a sweeper would, one at a time,
each reverted after reading. **They do not all fail the same way, and one does
not fail at all.**

```
site                                translated to      result
---------------------------------------------------------------------------
cbor_test.dart:138                  '☺'   -> ':)'      FAILS, loudly
    expect(bytesToHex(...), equals('63e298ba'))         the hex stops matching

audit_header_ascii_test.dart:27     'тест 🚀'          FAILS, loudly
    expect(isValidHeaderValue(x), isFalse)  -> 'test rocket'
                                                        ASCII IS valid, so the
                                                        assertion inverts

optimized_cbor_test.dart:164        'Привет, мир!'     PASSES
    round-trip through encode/decode  -> 'Hello, world!'
```

**The third is the class that matters.** A round-trip fixture asserts
`decoded == original`, which holds for any string at all. Translate it and the
suite stays green while the coverage — does this codec handle multi-byte UTF-8
— is gone, with nothing anywhere to say so.

And it is the MAJORITY shape: `error_details_test.dart:266-277`,
`cbor_test.dart:374/404/421`, `optimized_cbor_test.dart:76` and `:162-168`, and
all of `fast_cbor_encoder_test.dart` are round-trips. Only two sites in the
whole census fail loudly. "The gate would have caught it" was the assumption
worth testing, and it is false for ten of twelve.

Also run, and green:

```
test/zero_copy/     29 tests pass, run not merely analysed
melos run test:web  SUCCESS
```

`test:web` was run because `zero_copy_streams_test.dart` carries a dart2js
constraint in a comment — "dart2js schedules more coarsely, so poll for all
three with a deadline" — and a comment that states a constraint is the kind
most easily lost in translation. It is intact and the web target agrees.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run test:web       SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

## Not fixed

```
lib/ logs        39 lines   rpc_notify only    DEFERRED BY THE OWNER'S ORDER
lib/ comments   277 lines   23 files           same
test/          1069 lines   26 core files      in scope, open
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

**The owner's call to make.** Round 435 measured that 39 of the deferred `lib/`
lines are runtime log messages in a published package — the only category a
user meets without opening a file. The deferral was taken on the premise that
`lib/` is "outside the mandate", which is still true; what has changed is that
the deferred half is now known to contain something the in-scope half does not.
Whether that reverses the order is not the round's to decide (L-13: a decision
inherits the sentence it was taken on, and the sentence has moved).

The remaining 26 core test files cannot be swept from a file list — see C-47.
Whatever takes them needs the line-level census, and `cbor_test.dart`,
`optimized_cbor_test.dart` and `fast_cbor_encoder_test.dart` are the three that
mix both kinds.

## Links

- B-30 — `test/zero_copy/` done; the core remainder needs a line-level detector
- C-47 — the non-ASCII that must stay, all 12 sites, both rounds
- L-12 — third instance: the class was tabulated by file, and the axis that
  matters here is the LINE
- RPC-23 — the narrative beside the code
