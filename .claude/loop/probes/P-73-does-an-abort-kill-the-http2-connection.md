---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/abort_kills_the_connection.dart
round: 398
commit: 69d24a76
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
status: valid
---

# P-73 — does aborting a bidi call kill the HTTP/2 connection?

> **Round 398 reused it unchanged to settle B-53, with the DEPENDENCY VERSION as
> the only variable.** Same source both sides, `http2` pinned:
>
> ```
> arm                                 2.3.1         3.1.0
> abort racing responses, awaited     5 of 5 DEAD   5 of 5 pong
> abort racing responses, unawaited   5 of 5 DEAD   5 of 5 pong
> the six other arms                  clean         clean
> ```
>
> That is what this probe is FOR, and round 398 reached for a skipped test
> first — five green runs that could not see the defect, because the test only
> ever failed under workspace load while these arms are deterministic (L-17).
> A probe built for one question answers it on a machine at any load.

## Why it exists

Round 384's fix made an erroring request sink abort the call, and the http2
witness then failed on the NEXT unary with *"connection is no longer active"*.
The notice goes out as RST_STREAM here (`IRpcStreamReset`), which is legal, so
the question is what actually separates the runs that survive from the runs
that do not.

## Measures

One thing, after every call: a unary ping on the SAME connection. `pong`,
`HUNG`, or the status the transport reports. Five calls per arm, each arm on its
own fresh server and connection.

## Control

The arms ARE the control matrix — each pair differs by one variable, and the
half-close arm is the ending that must never kill anything:

```
arm                                    handler   abort timing        connection
abortWhileEmitting                     answers   30 ms settle        alive
abortWhenIdle                          silent    30 ms settle        alive
abort racing responses, awaited        answers   no settle           DEAD
abort racing responses, unawaited      answers   no settle           DEAD (races)
sinkErrors (echo)                      answers   from onError        see below
sinkErrors (silent)                    silent    from onError        alive
endpoint API, erroring requests        answers   via cleanup()       alive
halfClose (control)                    answers   finishSending       alive
```

Two variables are eliminated by it. Not the await: the awaited arm dies too.
Not the sink path: the raw public `abort()` dies with no new code in it. What
remains is **responses in flight at the instant of the reset** — every dead arm
has an answering handler and no settle, every live arm has one or the other.

`sinkErrors (echo)` is the arm the round moved: DEAD at call 1-2 before adding
`close()` to the fix, alive for all five after. It is also the arm that shows
the close is a narrowing and not a cure — under workspace load the same case
still failed.

## What it establishes, and what it does not

Establishes: on HTTP/2, a client-side stream reset that races responses still in
flight destroys the whole connection, taking every other call on it down. It is
reachable from the public `abort()` API without any of round 384's code.

Does not establish WHICH side closes the connection, nor the mechanism inside
`package:http2` — the probe reads only the client's verdict
(`!_connection.isOpen`, no GOAWAY recorded, no active streams). That is B-53's
first job. Nor whether the websocket and isolate transports have an analogue:
their notice is a metadata frame, not a reset, and both stayed clean.
