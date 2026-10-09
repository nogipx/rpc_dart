---
round: 757
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-02
bench: P-08 — reused
commit: yes
release: none
---

# Round 757 — the refusal trailers re-swept

## Target

RPC-02, `swept here (round 734)`, which `next` lists among swept lenses whose
paths moved: 9 files since, rounds 746-756 among them. The lens's own record
asks the next round to ablate rather than re-read. B-267 and B-270 not taken.

## Hypothesis

A refusal or cancel trailer added or changed since round 734 carries a
message with no `maxMessageLength`, so at a tight `maxHeaderValueBytes` the
explanation outgrows the policy that sends it.

## Before

Sweep: every `RpcMetadata.forTrailer(` call in core and the four transports,
arguments read to the balanced paren so a cap behind a comment counts:

```
  21 sites   16 with a message, 15 capped   5 without a message
  uncapped:  unary/responder.dart _dropLateResponse, message: <token reason>
```

P-08 re-run, unchanged from rounds 216 and 327:

```
  cap 8192   unimplemented 12   un-consumed window 8   plain call ok
  cap 64     unimplemented 12   un-consumed window 8   plain call ok
  cap 16     RpcMetadataViolation on every row (C-21's floor)
```

## Mechanism

`_dropLateResponse` sends the token's reason uncapped, but no reachable
reason outgrows a working cap. A peer's cancel closes the responder first, and
a closed one writes nothing: `r757_late_trailer.dart` sent a 60-char reason
of `%` (180 bytes encoded, cap 64) and of `a`, and the client saw no trailer
in either arm. Connection loss has nowhere to send. Drain, deadline and
endpoint close use `'server draining'`, `'deadline exceeded'`,
`'endpoint closed'`, at most 17 plain characters, under any cap above C-21's
floor of about 40.

## After

n/a — nothing changed.

## Canary

The ablation the lens asked for: `maxMessageLength` removed from
`_fcRefuseOverrun`'s trailer, cap 64, `un-consumed window` turned from status
8 to status 13 while the other rows held. Round 327 read a raw
`ArgumentError` there; the send has since gained a `catchError`, so the
symptom changed and the bench still sees it. Restored; `git status` clean.

## The verdict questions

1. Yes: the ablation differs from the run only in the one cap.
2. Yes: 8 against 13 on that row.
3. In the caller's status, through a real http2 connection.
4. The CLEAN rests on the ablated row moving, and on the uncapped site's
   reachable reasons being listed from the code that sets them.
5. n/a, no fix; the ablation row is quoted.
6. n/a.
7. CLEAN with a valid control: the bench sees a missing cap.
8. The uncapped site was set aside on today's code and the late-trailer bench,
   not on round 734's text. B-267, B-270 left open.
9. None.
A1. n/a.
A2. Volume: a message length against a cap.
L1. The refusal row names `maxHeaderValueBytes`'s cap, not a neighbour.

## Gate

n/a — no code change; `lib/` restored after the ablation.

## Not fixed

`_dropLateResponse` keeps an uncapped message. Capping it is the idiom of the
other 15 sites, but no witness can fail today, so it is not a round's fix.
The late-trailer bench is not registered: its control read the same as its
case, because a peer's cancel never reaches the site.

## Links

Lens `../lenses/RPC-02-refusal-trailer-violates-policy.md` — `applied: [..., 757]`,
`swept here (round 757, bdebb983)`.
Bench `../probes/P-08-refusal-survives-a-tight-cap.md` — reused.
`../checked/C-21-header-cap-has-a-floor.md`.
