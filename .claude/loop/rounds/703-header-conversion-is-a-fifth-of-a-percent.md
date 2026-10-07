---
round: 703
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-10
bench: none — `.dart_tool/probe/b193_bench.dart`, header helpers timed alone and a unary call over h2 loopback
commit: yes
release: none
---

# Round 703 — header conversion is a fifth of a percent

## Target

B-193's remaining cost items: request headers re-validated after
`validateMetadata`, rebuilt per call, and walked two or three times on the way
in (`String.fromCharCodes` per header in each of `extractMethodPath`,
`extractRequestMethod`, `http2HeadersToRpcMetadata`). The lead's witness:
requests per second with the header conversion profiled.

## Hypothesis

The work is real but small against a call.

## Before

Load 4.3 at the start. Five metadata headers, as the caller pipeline sends;
200000 conversions, three rounds; then 5000 unary calls over h2 loopback after
2000 warm-up, three rounds:

```
build (rpcMetadataToHttp2RequestHeaders)            0.724-0.764 us per request
parse (http2HeadersToRpcMetadata + two extracts)    0.250-0.273 us per request
unary over h2, whole call                           473.7-518.9 us per call
```

About 1 us of about 475 us: 0.2%. Responses and trailers go through the same
helpers, so the whole call's header work is at most a few times that, still
under 1%.

## Mechanism

None to fix: one conversion pass, cached constant headers and a merged walk
would save a fraction of a microsecond per call.

## Fix

None.

## After

As Before.

## Canary

None for a clean result; the call's own time is the scale.

## The verdict questions

1. A clean round; the call time is the scale.
2. Yes: the cost the lead named.
3. Yes: time per request.
4. Not zero-valued.
5. Yes, quoted.
6. -
7. Not a trade: nothing changes.
8. None.

## Gate

None needed: no code changed.

## Not fixed

B-193's small items with no failure behind them are left: the response
builder does not itself add `content-type` (the pipeline supplies it),
`filterStreamEvents` is used by tests only, the user-agent string is a fixed
`rpc-dart/1.0.0`, keepalive pings a busy connection, and the header guard and
proxy forwarder pass no pause/resume to the socket.

## Links

Lead `../backlog/B-193-http2-header-helpers.md` closed.
Lens `../lenses/RPC-10-shared-layer-blast-radius.md` -- `applied: [..., 703]`.
