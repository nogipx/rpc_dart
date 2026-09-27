---
round: 459
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-25
bench: none — the claim is about where a charge LIVES, so the evidence is a call graph and three greps, not a quantity
commit: yes
---

# Round 459 — the charge lives where they meet

## Target

B-79, the last of the three leads that shared one decision ("measure first, then
apply uniformly") with B-75 and B-80. Round 458 closed B-80 and, in passing, read
enough of http2's parser construction to make this one cheap.

## Hypothesis

If http2 charges nothing against a residency bound, the same inbound shape costs a
channel transport a refusal and http2 nothing.

## Before

No numbers, and the frontmatter says why: the claim is about WHERE a charge lives.
Three reads, and all three had to come back the way they did:

```
1  the parser buffer cap    http2 DOES pass it
     caller :1396, responder :627   maxBufferedBytes: _policy.maxBufferedBytes
     parser's null fallback is maxMessageLength + prefix (parser.dart:111-113),
     the same formula as effectiveMaxBufferedBytes -- so the two agree either way

2  the residency charge     lives in CORE, which http2 feeds
     bufferedBytes is a property of RpcTransportMessage (transport.dart:78);
     the charge is responder_pipeline.dart:1027 against _respMaxPreMethodBytes,
     and every transport feeds that pipeline

3  the window it protects   cannot open on HTTP/2
     it bounds payload buffered BEFORE the method is known; the http2 responder
     takes methodPath from the HEADERS frame (:584) and stamps it on every
     message it emits (:588, :600). In HTTP/2 the method is a `:path`
     pseudo-header, so it arrives on the frame that opens the stream
```

**So the lead's evidence is false as stated** — `maxBufferedBytes` appears twice in
`rpc_dart_http2/lib` — and its concern confuses two mechanisms, neither of which is
absent.

## Mechanism

A transport with nothing of its own to charge is the correct shape. The pre-method
budget exists because a channel transport can deliver payload on a stream whose
method has not arrived; HTTP/2 cannot, by the protocol's own framing. Pushing a
counter into http2 would bound a window that does not exist there.

## After

n/a — no source change. Negative in `checked/C-51`.

## Canary

n/a. What stands in for it: the mechanism was looked for in three places and the
third is what makes the second's absence correct rather than merely tolerable. If
the pipeline charge had been in a transport, or if http2 stamped `methodPath` only
on its headers message, the answer would have inverted — and both were checked, not
assumed.

## Gate

No source changed, so the gate is the journal's: `loop.py lint` green.

## Not fixed

**A coincidence left standing, deliberately.** http2 passes
`_policy.maxBufferedBytes`; core passes `policy.effectiveMaxBufferedBytes`. They
agree only because the parser repeats the fallback formula, which is the shape this
whole block of rounds has been unpicking. Making http2 pass the effective value
would state the agreement instead of relying on it — **and no canary could kill
that change**, because the behaviour is identical. Round 366 dropped a guard for
exactly that reason and round 452 added one on a sibling's shape while saying so;
this one is recorded rather than shipped.

**PEAK MEMORY is still unmeasured**, and it was the other half of B-79's bench
idea: whether `dart:io` has already committed the peak before this library sees a
byte. Nothing here needs it, and it stays the interesting question for anyone who
wants a number.

## Links

- RPC-25 — the shared layer is where a duty belongs, and an absent copy in a
  transport can be the correct answer; the mirror of round 451, where the sibling
  that answered the duty was also one layer up
- C-51 — http2 does charge the buffered bytes, in the layer it shares
- B-79 — closed by this round
- B-80 and B-75 — the other two leads that shared this decision; B-80 closed in
  458, B-75 re-framed in 451 and still open
