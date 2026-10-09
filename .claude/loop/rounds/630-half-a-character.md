---
round: 630
verdict: FIXED
packages: [rpc_dart]
lens: RPC-07
bench: none — the witness round-trips the trimmed message on VM and node
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S3
---

# Round 630 — half a character

## Target

B-237, from the audit of 2026-10-02: a trimmed `grpc-message` splits a UTF-8
character.

## Hypothesis

`encodeGrpcMessage` caps the encoded text by character count and only avoids
cutting a `%HH` triplet; it can still cut between the bytes of one multi-byte
character.

## Before

```
'Ж' x 200                  decoded ends in U+FFFD, not a prefix
'x' x 1020 + 'Ж'           decoded ends in U+FFFD, not a prefix
'x' x 1015 + two emoji     decoded ends in U+FFFD, not a prefix
```

A Cyrillic character costs 6 encoded characters, so any Russian message over
about 170 characters reached this under the default cap.

## Control

ASCII messages of any length trim to an exact prefix, before and after.

## Mechanism

The loop encoded byte by byte and stopped at the cap; the triplet trim kept each
`%HH` whole but not the sequence of triplets one character needs.

## After

The message is encoded one character (rune) at a time, and a character that
would cross the cap is left out whole. All three cases decode to a prefix with
no U+FFFD, on VM and node; the encoded text stays within the cap; a short
message with `%` and Cyrillic round-trips unchanged; `test/core` 389 green.

## Canary

The before table is the same witness against the byte-wise loop.

## Gate

`analyze` and `format` on rpc_dart green, the witness green on node, `melos run
test:unit` green (exit 0).

## Not fixed

Nothing left in the lead.

## Links

Lead `../backlog/B-237-a-trimmed-message-splits-a-character.md` — closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [..., 630]`.
Test `packages/core/rpc_dart/test/core/a_trimmed_message_keeps_whole_characters_test.dart`.
