---
round: 399
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-85 — new
commit: yes
---

# Round 399 — refused is cheaper, except to answer

## Target

B-58's cost half, filed by round 397 two rounds ago. That round made
`_answerFramingViolation` release its stream and deliberately did NOT give it
the 256-violation backstop its sibling `_answerRejectedStream` has, because the
same catch covers a resource limit a legitimate client can correct. The lead
said plainly that the cost side had no number.

RPC-22's own Ask decides it: *which is cheaper for an attacker — being accepted,
or being refused?* If refused, the refusal path is the attack surface.

## Hypothesis

A framing-violation grind is cheap enough for the peer and dear enough for the
server that the missing backstop matters.

## Before

P-85, new. 2000 operations on ONE connection through a byte-counting relay,
because neither endpoint can report both directions without the other's
cooperation:

```
arm            ops     ms    up B/op  down B/op   amp    status
served        2000    873      164.3      128.0   0.78x   0
framing       2000    548      134.0      216.0   1.61x   8
tight msg     2000    424      134.0      131.0   0.98x   8
:method GET    300     66      133.0      162.5   1.22x   3
```

The hypothesis is refuted on the half that matters. **The server does LESS work
per refusal than per honest call** — 548 ms against 873 for the same 2000
operations — so a peer grinding refused frames is doing less damage than the
same peer making real calls, which nothing bounds either. It is also cheaper for
the peer to SEND (134 against 164 B/op), which is RPC-22's trigger; but the
lens's rule assumes the cheap path costs the SERVER something, and here it does
not.

`:method GET` is the contrast B-58 asked for, and it shows the backstop working
on the sibling site: 300 attempted, the connection closed after the 256th
violation, against `framing` carrying all 2000.

## Mechanism

The one thing the refusal is worse at is answering. It is the only path here
where the server writes more than it reads — 216 bytes out for 134 in — and
`tight msg` says what those bytes are: the same arm with
`maxHeaderValueBytes: 24`, still `grpc-status 8` so still the same site, reads
**131 down and 0.98x**. The parser's own diagnostic (*"gRPC frame payload is too
large: 33554432 bytes (max: 16777216)"*) is the amplification.

That is a trade round 397 made knowingly and the numbers do not overturn: the
message is what lets a client fix its own request, 1.61x is not a reflector
anyone can aim (TCP will not carry a spoofed source), and the text is already
bounded by `maxHeaderValueBytes`.

## After

n/a — nothing changed. B-58's cost half is answered: **no backstop is justified
on cost.**

## Canary

n/a — no fix. The variation is `tight msg`, which holds the site and the arm
fixed and varies only the length of the answer, turning "the refusal writes
more" into "the refusal's MESSAGE writes more".

**And the round's own first version of that arm was void.** At
`maxHeaderValueBytes: 8` it came back `status 3, 300 ops` — `validateMetadata`
refusing the request's own `content-type: application/grpc`, so it measured the
headers site and its backstop, never reaching the framing site. The
`grpc-status` column caught it, the same column P-84 grew after round 395 made
the same mistake. Two rounds apart, same trap, same instrument.

## Gate

Not run: no library code changed. The only new file is a probe, which lives
under `.dart_tool/probe/` and is outside analysis and the suite by design.

## Not fixed

B-58 stays open, narrowed to the half a measurement cannot settle: should
`closeOnProtocolError` fire for malformed framing — the `RpcStatus.internal`
branch, as opposed to the resource-limit one? That is a question about what the
field MEANS, and nothing is broken while it goes unanswered, which is now
measured rather than assumed.

## Links

- B-58 — cost half answered here, decision half untouched
- RPC-22 — `applied:` gains 399; its Ask needs a second clause
- P-85 — new
- P-84 — where the `grpc-status` column came from, and why this round had one
