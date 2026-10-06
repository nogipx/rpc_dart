---
round: 664
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-229 — new
commit: yes
release: changelog
---

# Round 664 — a failed response keeps downloading

## Target

B-188, filed from the audit's static read: the http2 caller fails a call on its
headers and keeps reading the body. RPC-22 asked from the caller's side: every
exit where the caller has already said no, and which of them stop the stream.

Scope, counted before the fix: five exits in `rpc_http2_caller_transport.dart`
end a call on this side's verdict -- non-200, non-gRPC content-type, headers the
policy refuses (the `rethrow` into `_handleIncomingMessage`'s catch), a DATA
frame that does not parse (`_handleDataMessage`'s catch), and the un-consumed
window. The window already resets. All four others are in scope, plus the
lead's second claim, 1xx.

Not touched: B-186 shares `_fcOnDelivered`'s error-then-reset path; it is its
own lead.

## Hypothesis

None of the four exits resets the stream, so a body after the verdict is
downloaded to the end and every DATA frame reaches the parser.

## Before

```
direct   html503    ERROR 128  broadcast errors after the end 64  sent 1024 KiB  RST no
direct   garbage    consumer errors 64   ERROR 128               sent 1024 KiB  RST no
direct   badmeta    consumer errors 65   ERROR 129               sent 1024 KiB  RST no
endpoint early      "status 2" -- a valid answer behind a 103 fails
```

Through the endpoint the 503 costs 32 KiB and 2 ERROR records, because the
endpoint releases the id when the call ends. A transport user that does not
release (or the window before the release lands) gets the full body.

## Mechanism

The non-200 and content-type branches emit a terminal status and return; the
two catches emit an error and return. No path cancels the http2 subscription,
so DATA keeps arriving and is parsed against a stream whose consumer has gone.
A 1xx reaches the non-200 branch because only 200 is special-cased.

## Fix

`_dropFailedResponse` resets the stream right after each of the four exits
reports its failure (the order matters: `resetStream` suppresses later errors).
A 1xx header block returns without effect.

## After

```
direct   html503/ct ERROR 0   sent 16-32 KiB  RST yes
direct   garbage    consumer errors 1  ERROR 2 (parser + transport)  RST yes
direct   badmeta    consumer errors 1  ERROR 1                      RST yes
endpoint early      "ok ok"
```

## Canary

Two halves, two canaries, on
`packages/transport/rpc_dart_http2/test/a_failed_response_is_not_downloaded_test.dart`:

- `_dropFailedResponse` returning early: all four reset arms red -- the two HTML
  arms with `Expected: true Actual: <false> the peer must see RST_STREAM once
  the call has failed`, the policy and parse arms with `Expected: ['error']`
  against 65 errors.
- the 1xx guard narrowed to nothing: the 103 arm red with
  `RpcStatusException(2): HTTP status 103`.

Both restored: 5 of 5 green.

## The verdict questions

1. Yes: the canary differs from the fix by the reset alone; `ok` is unchanged.
2. Yes: 1024 KiB and 128 ERROR before, 16-32 KiB and 0 after.
3. Yes: bytes sent and `onTerminated` at the peer; ERROR counted on the
   library's own `LogScope`.
4. Yes: the same exits emitted 128 records before; 600 ms after each call
   covers a 64-chunk send that takes ~150 ms.
5. Yes, quoted above.
6. Yes, two.
7. Yes.
8. None.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart_http2 +280); `format:check` clean; `license:check` compliant.

## Not fixed

Nothing on B-188. B-186 (the overrunning message delivered after its error) is
the same file's remaining error-ordering lead.

## Links

Lead `../backlog/B-188-http2-a-failed-response-keeps-downloading.md` closed.
Bench `../probes/P-229-what-a-failed-response-still-downloads.md`.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` --
`applied: [..., 664]`.
