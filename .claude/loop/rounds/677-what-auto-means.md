---
round: 677
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — the lead's own probe, `.dart_tool/probe/codec_mode_response.dart`, re-run; the fix is prose, pinned by a witness of the behaviour it now states
commit: yes
release: changelog
---

# Round 677 — what `auto` means

## Target

B-250, core, decided by the owner: fix the enum's doc to match the code. The
doc said `auto` "picks based on codec presence (codecs -> codec mode)"; the
unary caller passes objects under `auto` whenever the transport can. One site,
`models.dart`; the caller's own comment already described the code.

## Hypothesis

With codecs given, `auto` does not serialize a unary call on memory and
isolate, so the message limit does not apply.

## Before

`codec_mode_response.dart`, limit 64 KiB, 66560-byte messages:

```
memory   mode=codec  request over limit   8
memory   mode=auto   request over limit   OK
memory   mode=auto   response over limit  OK len=66560
isolate  the same
```

The doc predicted 8 for `auto` with codecs.

## Mechanism

`UnaryCaller` takes the object path when `_transferMode != codec` and
`transport.supportsZeroCopy`. Streaming shapes decide on codec presence alone,
so they serialize whenever codecs are given.

## Fix

The `auto` doc states that: unary passes objects where the transport can,
codecs or not, with no limit because there are no bytes; streaming shapes with
codecs serialize; `codec` serializes everywhere. Behaviour unchanged, by the
owner's choice (the object path is 514 us against 807 us per round trip).

## After

The doc and the probe agree. Pinned by
`packages/core/rpc_dart/test/contracts/auto_mode_does_what_its_doc_says_test.dart`:
`auto` over the limit OK, `codec` 8.

## Canary

The code made to do what the OLD doc said (object path for `zeroCopy` only):
`Expected: 'ok 66560' Actual: 'status 8'`. Restored: green. The witness pins
the documented behaviour, so a future change to either reads red.

## The verdict questions

1. Yes: the canary changes the one branch the doc describes.
2. Yes: OK against 8.
3. Yes: the call's outcome.
4. Not zero-valued.
5. Yes, quoted.
6. One half.
7. Yes; prose fixed by the owner's choice.
8. None.

## Gate

`analyze`, `test:unit` (15 packages), `format:check`, `license:check` green.

## Not fixed

Nothing on B-250.

## Links

Lead `../backlog/B-250-auto-mode-skips-codecs-and-limits-on-unary-only.md` closed.
Lens `../lenses/RPC-23-the-narrative-beside-the-code.md` -- `applied: [..., 677]`.
