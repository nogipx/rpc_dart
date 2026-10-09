---
round: 567
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-08
bench: P-189 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
severity: S2
---

# Round 567 — our limit on their answer

## Target

`B-181` from the audit intake, chosen over `B-215` because that lead's own first requirement is
a quiet machine and the 15-minute load average is 12-14. It is the sharpest unmeasured claim in
the intake: a status destroyed is visible to every caller talking to a non-Dart server, and
`C-61` says the intake's own severity lines cannot be trusted either way, so it needed measuring
rather than ranking.

**Scope decided before the fix: two sites, both of them.** The lead names only the http2 caller.
Sweeping `validateMetadata` across every `lib/` found a second inbound caller-side instance —
core's `RpcChannelTransport._validateInbound`, which websocket, isolate and in-memory all
inherit. The HTTP/1.1 caller's call is OUTBOUND, and that it does NOT validate inbound response
headers is a different lead (`B-145`).

Lens RPC-08: one rule, two sides, applied on one of them.

## Hypothesis

Our metadata limits run over the PEER's trailers before the status is read out of them, so a
limit tripped by a detail header replaces the server's status with ours.

## Before

```
http2 caller, raw package:http2 server answering grpc-status 9
  CONTROL  details-bin 16 B      status 9 -- the precondition failed
  WITNESS  details-bin 10 KiB    status 3 -- Invalid metadata header value
  WITNESS  200 trailer headers   status 3 -- Too many metadata headers

core channel transport, client role
  CONTROL  details 16 B          frames [frame(no status), status 9]   errors none
  WITNESS  details 10 KiB        frames [frame(no status)]             errors RpcFrameException
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/b181_foreign_trailers.dart`. Same
trailers, same `grpc-status: 9`; only the size or count of an unrelated detail header differs.
`maxHeaderValueBytes` defaults to 8 KiB, and `grpc-status-details-bin` is where grpc-go puts
rich error details, so 10 KiB is the ordinary interop case rather than an attack.

## Mechanism

`_handleHeadersMessage` converts and validates, then reads `grpc-status` out of the result — so
a throw in either step means the status is never read. One frame out the throw becomes a stream
error, `_statusReceived` stays unset, and the stream's end synthesises UNAVAILABLE behind the
error the consumer already got. Core's `_validateInbound` returned a bool and the caller dropped
the frame outright.

**The limits cannot protect anything here**: the frame is HPACK-decoded and resident before
either check runs. Refusing it buys no memory; it only decided whose answer ended the call.

## After

```
http2 caller
  CONTROL  details-bin 16 B      status 9   unchanged
  WITNESS  details-bin 10 KiB    status 9
  WITNESS  200 trailer headers   status 9

core channel transport
  CONTROL  details 16 B          frames [frame(no status), status 9]   unchanged
  WITNESS  details 10 KiB        frames [frame(no status), status 9]   errors none
```

One rule at both sites: **a response frame carrying `grpc-status` is reduced to that status
rather than refused.** `grpc-message` rides along only when it passes the check the peer just
failed — it may BE the offending value — and the violation is still charged to the 256-violation
budget, because a peer that does this 256 times is not one rich error.

**CLIENT role only, in core.** A responder has its own answer to send and still sends it; and a
hostile client could otherwise put `grpc-status` on a REQUEST to get a frame delivered where
this used to refuse it. The http2 site is a caller transport by construction.

The http2 half reads the status from the RAW headers, because
`http2HeadersToRpcMetadata` throws on `maxHeaders` partway through its own walk and never
returns metadata to read.

## Canary

Two, one per site.

```
A. http2, `1 > 0 ? null : _peerStatusOnly(...)`
     both witnesses   Expected: <9>  Actual: <3>
     CONTROL and the connection GUARD pass

B. core, `(isClient && 1 < 0)`
     a trailer over the policy keeps its grpc-status
       Expected: empty
         Actual: [RpcFrameException:RpcStatusException(3): Inbound metadata
                  violates the security policy on stream 2: Invalid metadata
                  header value for: grpc-status-details-bin]
     an oversized grpc-message is dropped and the status still lands
         Actual: [... Invalid metadata header value for: grpc-message]
     the eight pre-existing tests in that file pass
```

Each site's witnesses fail only under its own ablation, which is what says the two fixes are
independent rather than one masking the other (`L-01`).

**The controls are what stop this being "the limit stopped applying to trailers"**: a frame over
the policy with NO status is still refused, and the small-details arm still reads 9.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart +1868 ~1,
                                           rpc_dart_http2 +263
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2167 / 2167, REUSE compliant
```

**The first `test:unit` run FAILED and the failure cannot be named, because the output was
piped through `tail` and the failing test scrolled past** — round 542's mistake, repeated here
knowing better. Re-run with the failure lines captured in the same invocation it was green
across all 15 packages, and `rpc_dart` alone was green at `+1868 ~1`. Load averages were
`5.61 12.04 12.27`, the condition `config.md` names. Recorded as a flake that was NOT named
rather than as a pass.

## Not fixed

**The synthesised UNAVAILABLE behind the error was never observed**, which is half of what the
lead predicted. The violation reached the caller first and failed the call, so the second
terminal event never surfaced — `B-189` is the lead for terminal events delivered twice, and
this is an instance of why it is hard to see.

**The responder side is deliberately unchanged** and it is a judgement, not a measurement: a
responder refusing a client's oversized headers answers with its own INVALID_ARGUMENT, so
nothing is destroyed. If a request ever needs to carry a status this is wrong, and nothing here
tested it.

**The HTTP/1.1 caller does not validate inbound response headers at all** (`B-145`), so it has
the opposite defect and is not an instance of this class. Not measured here.

## Links

Lead `../backlog/B-181-http2-policy-is-applied-to-foreign-trailers.md` — CLOSED, with the
second site it did not name.
Lead `../backlog/B-145-http1-response-headers-are-not-validated.md` — the opposite defect on
HTTP/1.1.
Lead `../backlog/B-189-http2-terminal-events-are-delivered-twice.md` — why the predicted second
event was not visible.
Bench `../probes/P-189-whose-answer-ends-the-call.md` — new, both sites in one file.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [567]`.
Lesson: none. RPC-08 and `L-12` already carry what this round applied — sweep the class before
fixing any of it, and the count went into `## Target` before the first edit.
