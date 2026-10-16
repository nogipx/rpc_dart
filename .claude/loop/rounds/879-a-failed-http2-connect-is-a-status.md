---
round: 879
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-300 — reused
commit: yes
release: breaking
severity: S2 — "a status or error type a caller branches on"
---

# Round 879 — a failed http2 connect is a status

## Target

B-289, decided by the owner on 2026-10-16: do it the way round 814 did.
The owner also asked for the TLS and proxy failures to be measured here.

## Hypothesis

`connect` and `secureConnect` pass on whatever their connection factory
throws.

## Before

```
P-300 refused: ws 14, http 14, http2 OSError
witness arms with the mapping off (canary):
  refused connect / secureConnect  OSError
  TLS handshake to a non-TLS peer  HandshakeException
  proxy answers 407 / refused      SocketException
```

## Mechanism

Both factories (`createConnection`) ran unguarded. They serve the first
connect and every `reconnect`. Now `_asStatus` wraps them as round 814 did:
an `RpcException` or an `Error` passes through unchanged, and any other
`Exception` becomes UNAVAILABLE with its text kept.

A first draft also redacted the proxy's userinfo from that text. No failure
path puts the userinfo there: the proxy errors quote the status line or the
address. So the redaction was removed. The witness keeps a GUARD row that
the password does not appear.

## After

The witness `test/a_failed_connect_is_a_status_test.dart`: all 5 arms
give `status 14`.

## Canary

Mapping off (`1 > 0 ||`): 5 rows red. Actual values: `'OSError'`,
`'OSError'`, `'HandshakeException'`, `'SocketException'` and
`'SocketException'`.

## Gate

`melos run analyze` SUCCESS; `format:check` SUCCESS; `license:check`
compliant. `melos run test:unit:quiet --no-select` SUCCESS once the load
average had fallen to about 5 (rpc_dart +2265 ~1, http2 +369, http +261,
websocket +331, isolate +102, conformance +620 ~152). Before that,
`test:unit` was NOT green in any of four runs. Each run failed one to three tests, a different set each time, all of
them timing tests: conformance i1 (http) and i3 (socket), http and http2
`graceful_drain_on_stop_test`, http2 `tiny_messages_are_weighed_test`,
isolate `isolate_verification_test` parallel, and
`audit_frame_reassembly_linear_test`. Every one is green alone, and so are
core, conformance and http2 run together at `-j 12`. None touches the
connect path changed here. The machine's load average was about 25 while
another application built. The class is recorded in B-297.
`proxy_connect_limits_test` now expects an `RpcStatusException` 14 that
carries the same text. `tls_through_a_proxy_test` now reads the handshake
text from the status.

## Siblings

- http2: fixed here
- http: already a status (`_asRpcStatus`), the reference
- websocket: round 814
- channel: n/a, the application opens the channel
- isolate: n/a, no network connect
- wasm: n/a, no network connect
- caller: fixed here
- responder: n/a, nothing to connect

## Not fixed

A silent peer that never sends SETTINGS still does not fail `connect`; it
fails the first call. That is unchanged.

CHANGELOG (breaking): "rpc_dart_http2: `connect` and `secureConnect` (and
`reconnect`) throw `RpcStatusException(UNAVAILABLE)` instead of dart:io's
`SocketException`, `OSError` or `HandshakeException`; the original text is
in the message."

## Links

Lead `../backlog/B-289-http2-connect-throws-raw-io-errors.md`. Round
`814-a-failed-websocket-connect-is-a-status.md`.
