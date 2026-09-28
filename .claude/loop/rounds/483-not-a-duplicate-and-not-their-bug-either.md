---
round: 483
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-13
bench: P-122 — reused
commit: yes
---

# Round 483 — not a duplicate, and not their bug either

## Target

B-35's report, before it is posted. Round 480 established the bug is not FIXED
upstream and stopped there. **That is only half the duplicate check** — a report
also wastes a maintainer's time if the bug is already REPORTED, and nothing had
looked.

Small round, and the last thing on this lead that is not the owner pressing
send.

## Hypothesis

Either it is already filed, in which case the deliverable changes from "post
this" to "add the reproduction to that", or it is not and the report stands.

## Before

`dart-lang/http`, the monorepo `package:http2` now lives in. All 12 open
`package:http2` issues read, plus a full-text search for the error string:

```
#1597  "Bad state: Cannot add event after closing"   package:web_socket_channel,
                                                      closed 2019 — wrong package
#1364  "Can't catch exception occur during goaway"   StreamException is not
                                                      EXPORTED; an API-surface
                                                      complaint, not this
#1380  "How to catch the exception thrown by         same FAMILY, different
        ClientTransportConnection.terminate?"         error, different call
```

**Not a duplicate.** The exact-string hit is a different package, and #1364 —
which by title looks like ours — is about a type not being exported so callers
can identify it, not about an uncatchable `StateError`.

## Mechanism

None. Nothing in this repository changed; the round's output is a check and one
new probe arm.

## After

#1380 is the interesting one, and the reason it needed an arm rather than an
opinion. It is the same family — a teardown error that neither `try/catch` nor
`.catchError` can hold — open and unanswered since June 2023 **with no
reproduction**. Its error is `TransportConnectionException` "Connection is being
forcefully terminated", from `terminate()`.

**None of P-122's five arms could speak to it**, and the reason is a trap this
round nearly walked into: every one of them terminates with the stream already
ENDED, because the harness was deliberately changed to do that so `finish()`
would return at all. #1380's shape is the opposite — a request still in flight.

So the sixth arm drives exactly that: `makeRequest`, `sendData`, no `endStream`,
then an AWAITED `terminate()` inside a `try/catch`, which is what the reporter
describes doing.

```
terminate() with a stream IN FLIGHT   silent
```

Silent, and nothing caught at the call site either. **It does not reproduce on
3.1.0** and may well have been fixed since 2023.

## Canary

No fix, so nothing to switch off. The arm carries its own: the five existing
arms are the control for the sixth, and they establish that this harness CAN
produce an uncaught zone error — it does so five times out of five on the
`finish()` arm in the same run. So "silent" on the in-flight arm is a
measurement and not a harness that cannot see anything.

## What the round actually bought

A sentence that will NOT go upstream. The tempting write-up was *"this is also
#1380, here is the reproduction they never gave you"* — a 3-year-old unanswered
issue explained, which is exactly the kind of claim a maintainer would check
first and a reporter would most like to be true. It is unsupported: driving
#1380's shape produces nothing.

The report now mentions #1380 as related, says plainly that it did not
reproduce, and does not assert a link.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. No tracked source changed —
the probe is under `.dart_tool/`.

## Not fixed

**Still not posted**, and that is unchanged: publishing is outward-facing and
the owner's name goes on it. What changed is that it is now checked against the
tracker, so pressing send is the only remaining step.

**#1380 is not resolved by this.** It did not reproduce from its description,
which is not the same as it not existing — no version is given in the issue and
the reporter's transport setup is not fully described. Left as a link.

## Links

- B-35 — the lead, now carrying the duplicate check and the related-issue line
- P-122 — reused, extended with the in-flight arm
- Round 480 — which wrote the report and checked only that it was not fixed
- RPC-13 — an async error with no handler reaches the zone
