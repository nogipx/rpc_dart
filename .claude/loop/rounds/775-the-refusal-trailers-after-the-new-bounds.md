---
round: 775
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-02
bench: P-08 — reused
commit: yes
release: none
---

# Round 775 — the refusal trailers after the new bounds

## Target

RPC-02, swept in round 757; `next` lists 6 files moved under it since.
Round 770 changed when http2's un-consumed-window refusal fires (by the
backlog already waiting, not the message that arrived), which is one of
P-08's three paths: the bench could stop reaching it (L-15).

## Hypothesis

A refusal still reaches the caller with its own status under a tight
`maxHeaderValueBytes`, and the un-consumed-window path still fires.

## Before

P-08 (`refusal_survives_a_tight_cap.dart`):

```
  cap 8192   unimplemented 12   un-consumed window 8   plain call ok
  cap 64     unimplemented 12   un-consumed window 8   plain call ok
  cap 16     RpcMetadataViolation on all three (the caller's own request
             headers exceed 16 bytes: the control row that the cap bites)
```

## Mechanism

Unchanged since round 757: every refusal trailer is capped to the policy
before it is sent. The un-consumed-window row still reads 8, so P-08's
flood still builds a backlog past the window after round 770.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. The rows differ in the cap only.
2. Yes: the 16-byte row fails differently.
3. At the caller.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN: the same nine cells as round 757.
8. Nothing dismissed.
9. None.
A1. One policy per side.
A2. Volume.
L1. Each status names its own refusal.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Bench `../probes/P-08-refusal-survives-a-tight-cap.md`.
Round `770-http2-refused-every-message-larger-than-the-window.md`.
