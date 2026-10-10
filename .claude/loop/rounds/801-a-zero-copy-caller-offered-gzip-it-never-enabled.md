---
round: 801
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-292 — new
commit: yes
severity: S2
release: changelog
---

# Round 801 — a zero-copy caller offered gzip it never enabled

## Target

B-278, rank 1 after round 800: the matrix's I-3 cell said a paused isolate
caller did not hold a server stream's producer back by bytes (S1 as filed).
Taken because it was the highest open lead the matrix filed.

## Hypothesis

As filed: on isolate the byte window does not pace the producer. Two
narrower ones were measured and refuted first: that the policy's window is
lost on the way into the worker (`toMap` and `fromMap` carry it), and that the
producer never gives the event loop a turn for the grant to land (`turn` arm,
still 4000).

## Before

```
tight (paused caller)    4000 produced at 600 ms
turn  (event-loop turn)  4000 produced at 600 ms        <- not the loop
random (incompressible)    40 produced at 600 ms        <- the window holds
wire bytes per message:  66 (filler 'x'), 13.5 KB (random), of 16 KiB
read, all 4000           630 ms      read-identity   460 ms
```

Probe: `packages/transport/rpc_dart_isolate/.dart_tool/probe/r801_paused_caller_producer.dart`.

## Mechanism

The lead's premise was wrong: the window paces by WIRE bytes, as its doc
says, and the paused caller holds those bytes undecoded, so memory was
bounded. What the payload size exposed is that every isolate response was
gzipped. `RpcMetadata.forClientRequest` offers `identity,gzip` by default,
and the caller pipeline replaces that with `identity` (or the registered
encodings when `compressionEnabled`) only when the transport is NOT
zero-copy. On a zero-copy transport (isolate, `RpcChannelTransport.memoryPair`)
a codec call is framed like any other, so the default offer stood and the
responder compressed every message of a caller that never enabled
compression.

## After

```
read            452 ms      read-identity   452 ms      (was 630 against 460)
tight (paused)    34 produced at 600 ms                  (window: 512 KiB / 16 KiB)
I-3 isolate | server stream, caller paused: passes, un-marked
```

The accept-encoding header is set on every transport, zero-copy included.

## Canary

With the `!transport.supportsZeroCopy` condition put back:

```
a_zero_copy_transport_offers_no_unasked_compression_test:
  Expected: ['identity', 'identity', 'identity', 'identity']
    Actual: ['identity,gzip', 'identity,gzip', 'identity,gzip', 'identity,gzip']
I-3 isolate: the handler produced 181 messages of 16384 bytes past a paused
caller; the policy bounds it near 104
```

## The verdict questions

1. Yes: `read` and `read-identity` differ only in the offer; `tight` and
   `random` only in the payload's compressibility.
2. Yes: 630 against 460 ms, and 4000 against 40 produced.
3. The time on the caller; the produced count on the worker, by its handler.
4. n/a, not a zero.
5. Quoted.
6. One mechanism; the paired test pins that an enabled caller still offers
   what is registered.
7. From the table. S2, not S1: a measured cost (37% on this stream) and a
   wrong answer to the caller's setting; memory was never unbounded.
8. B-278's text was set aside by measurement: `random` showed the window
   holds. The other leads were not touched.
9. A count of messages is not a measure of memory when the transport may
   compress: the I-3 row reads "produced" as bytes. Not a lesson: the row
   passes now that nothing compresses unasked, and is recorded in
   `## Not fixed`.
10. Sibling lines below are measurements or a stated structure.
A1. n/a. A2. Neither: the gap is a header. L1. n/a.

## Gate

`melos run analyze`, `format:check`, `license:check`, `test:unit` (14
suites): green. `test:web`: red on the new test's paired case (no gzip codec
on the web), rewritten to expect what is registered; that file green on VM
and node. The whole `test:web` then three times: once red, `loading
test/web_worker/worker_startup_failure_test.dart [E]` and nothing else
failing (B-270's intermittent, recorded there), then green twice (15 suites).

## Siblings

- caller: fixed here
- responder: clean — it answers with what the caller offers: identity
  offered, identity used (`read-identity`, 452 ms; the core witness sees the
  header on all four shapes)

## Not fixed

- The I-3 paused-reader row counts produced messages, which reads as memory
  only while nothing compresses. A caller that enables compression would fail
  it with memory still bounded. Not changed: the row is the owner's
  invariant's test and passes as it stands.
- `RpcMetadata.forClientRequest` still offers `identity,gzip` to a caller that
  builds requests below the pipeline (processors used directly).
- Request compression on a zero-copy transport stays off even with
  `compressionEnabled`; unchanged, not measured.

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md`. New bench
`../probes/P-292-unasked-compression-on-a-zero-copy-transport.md`. Lead
`../backlog/B-278-a-paused-isolate-caller-does-not-hold-the-producer-by-bytes.md`,
closed with its premise corrected.
