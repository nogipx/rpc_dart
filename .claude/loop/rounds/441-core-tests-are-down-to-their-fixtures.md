---
round: 441
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is the count, and a correction
  to how the remainder has been reported for six rounds
commit: yes
---

# Round 441 — core's tests are down to their fixtures

## Target

**B-30**, the rest of `rpc_dart`'s tests: six files, 172 Cyrillic lines.

```
core/rpc_message_parser_test.dart             53
transports/in_memory_transport_streams_test.dart  31
core/rpc_stream_id_manager_test.dart          30
core/rpc_metadata_test.dart                   20
core/rpc_message_frame_test.dart              20
core/rpc_message_test.dart                    18
```

`lib/` remains deferred — sixth round inside the decided half, the owner's
question from 436 still open.

## Hypothesis

That these six files are the last of the decided scope, so sweeping them ends
it. Established, and it turned up something the check was not aimed at: the
remainder figure these rounds have been quoting spans three scopes, not one.

## Before

```
rpc_dart test/   172 Cyrillic lines outside the C-47 fixtures
```

## Mechanism

Not a behaviour defect. The repo diverging from "English for code, comments,
and logs".

## After

**`rpc_dart`'s test suite holds no Russian prose at all.** What remains in it is
exactly the C-47 fixture set:

```
core/error_details_test.dart              6   'ОШИБКА' / 'тест.v1' round-trip
serializers/cbor_test.dart                4   encodings pinned to hex
serializers/optimized_cbor_test.dart      3   the unicode corpus
serializers/fast_cbor_encoder_test.dart   2   'unicode_short'
serializers/cbor_parity_test.dart         1   the parity corpus
core/rpc_context_validation_test.dart     1   asserted to throw ArgumentError
audit/audit_header_ascii_test.dart        1   asserted INVALID as a header
```

453 tests pass across the files touched.

**No duplicate comment line existed in either of the two large files**, checked
with `sort | uniq -c` before editing per 439's rule, so every one of the ~84
edits was single-site and `replace_all` was not used at all.

## Canary

**A correction to this work's own reporting, which has been wrong for six
rounds.**

Rounds 435-440 each closed with a figure like "`test/` 443 lines across 21
files", written in a context that made it read as core's remainder. It is not.
Counted by package today:

```
rpc_notify    test/    230 lines across 3 files   never touched
rpc_data_postgres      17 lines across 2 files    never touched
rpc_dart      test/     18 lines                  C-47 fixtures only
```

So the `test/` total was always a repo-wide number, and **two packages'
worth of it has never been in any round's scope.** The sweeps ran core and
transport because that is what the owner's decision names; `rpc_notify` and
`rpc_data_postgres` sit outside the mandate exactly as `lib/` does. Nothing was
skipped silently — but nothing said so either, and a reader tracking 1338 down
to 443 would reasonably have concluded core was two-fifths done when it was
finished.

L-12 again, on the axis of PACKAGE: a count that spans scopes reads as progress
against one of them.

The prefix-damage detector was also re-run repo-wide. Four hits, all in
`rpc_notify`'s untouched tests, and all pre-existing Russian sentences opening
with an English identifier — `// Premium пользователи`, `// ID должны
увеличиваться`, `// finishSending может добавить`, `// Router генерирует`. Not
damage. Worth recording that the detector has a real false-positive rate
(4 in 230 lines) wherever a comment legitimately begins in English, so it is a
prompt to look, not a check that passes or fails.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

## Not fixed

```
lib/ logs        39 lines   rpc_notify only      deferred by the owner's ORDER
lib/ comments   277 lines   23 files             same
rpc_notify test 230 lines   3 files              OUTSIDE the mandate
postgres test    17 lines   2 files              OUTSIDE the mandate
generated        21 lines   rpc_data/*.g.dart    fix the SOURCE first
rpc_dart test    18 lines                        C-47 fixtures, permanent
```

**The decided half of B-30 is now complete.** Its owner decision (round 415)
reads "sweep the 47 `test/` and `example/` files inside core and transport
first" — `example/` went in 432, transport `test/` in 435, and core `test/`
ends here. Everything left is either an owner-deferred `lib/`, a package
outside the mandate, generated, or a fixture.

That makes the next round's target a question rather than a queue, and it is the
same question round 436 asked and 437-441 worked around.

## Links

- B-30 — the decided half is complete; what remains needs an owner decision
- C-47 — the fixture set is now the entire non-ASCII content of rpc_dart's tests
- L-12 — a count that spans scopes reads as progress against one of them
