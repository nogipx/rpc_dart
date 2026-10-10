---
round: 815
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-18
bench: P-301 — new
commit: yes
severity: S3
release: changelog
---

# Round 815 — a failed connect keeps its credentials

## Target

Round 814's `## Not fixed`: the UNAVAILABLE message it added quotes the
underlying error, and `openWebSocket`'s timeout text holds the full uri. The
README tells a web client to authenticate with a query parameter, so the
token is in that uri.

## Hypothesis

A failed websocket connect's error text carries the uri's userinfo and query,
so every log that records the failure (`RpcClientConnection` warns
`Attempt N failed: $e` on each attempt) records the credentials.

## Before

```
P-301 at 58008489:
  timeout, timeout compressed           userinfo+query
  closed mid-upgrade, closed compressed userinfo+query
  401 compressed                        userinfo+query
  401 (default handshake)               none
```

Not introduced by round 814: the raw dart:io errors carried the same text
before it.

## Mechanism

dart:io writes the request uri into `HttpException` (`uri = ...`) and into
`WebSocket.connect`'s refusal (`Connection to '...'`); our own
`TimeoutException` in `ws_open_io`/`ws_open_stub` does the same. The message
is built from `'$error'`, and that text reaches every log down the line.

## Fix

`_connectFailure` blanks the uri's userinfo and query in the quoted error
text (`<redacted>`), so it covers dart:io's texts and our own on both
platforms without naming a dart:io type. The host, port and path stay.

## After

P-301: no secret in any of the six. The http caller, measured as the sibling:
none before or after.

Witness: `a_failed_connect_is_a_status_test`, "the message carries no
userinfo and no query" (close mid-upgrade, the address still in the text).

## Canary

Redaction off (`if (1 < 0)`): the witness fails, `Expected: not contains
'pw-secret' Actual: '... uri = http://user:pw-secret@127.0.0.1:55417/rpc?token=q-secret'`.

## The verdict questions

1. Only the uri's credentials differ from round 814's bench.
2. Yes: five rows with the secret, none after.
3. At the caller: the error's text, which is what a log records.
4. n/a.
5. Quoted.
6. One change, one canary.
7. From the table.
8. none.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`dart analyze --fatal-infos` and the websocket suite (+312) green;
`websocket_web_smoke_test` on node green. Only rpc_dart_websocket changed.

## Siblings

- websocket: fixed here
- http: measured clean with the same bench (messages name the method path)
- http2: n/a, `connect` takes a host and a port, no uri with credentials
- channel: n/a, no uri
- isolate: n/a, no uri
- wasm: n/a, no uri
- caller: fixed here
- responder: n/a, nothing to connect

## Not fixed

- A user-supplied `reconnectFactory` on the constructor path is the
  application's code and is not wrapped.

CHANGELOG line: "rpc_dart_websocket: a failed `connect` no longer puts the
uri's userinfo or query string into the error message."

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Bench
`../probes/P-301-credentials-in-a-failed-connects-message.md`. Previous round
`814-a-failed-websocket-connect-is-a-status.md`.
