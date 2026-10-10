---
round: 829
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-25
bench: none — the witness test is the measurement; the probe is below
commit: yes
severity: S3
release: changelog
---

# Round 829 — the base url's password was in the log

## Target

rpc-design §10, "credentials never appear in logs or error messages", on the
http caller: the sibling of round 815, which redacted the websocket
connect's error text. dart:io's `HttpClient` takes Basic auth from a
`baseUrl`'s userinfo, so that is a real place for a password.

## Hypothesis

A failed request's error, its log record, or `health()` carries the
`baseUrl` with its userinfo.

## Before

Probe `packages/transport/rpc_dart_http/.dart_tool/probe/r829_secret_in_logs.dart`,
`baseUrl: 'http://user:pw-secret@127.0.0.1:<port>'`:

```
  failure    in the error   in the log            in health()'s text
  refused    no             0 of 1 records        no
  closed     no             1 of 1 records        no
     "HTTP request failed ... | ClientException: Connection closed before
      full header was received, uri=http://user:pw-secret@127.0.0.1:.../Svc/m"
```

And, read then measured by the witness: `health()` and `reconnect()` put
`'baseUrl': _baseUrl` in their details as given, password included.

## Mechanism

The catch logged the raw exception (`error: e`); `ClientException.toString`
prints its uri. The status the call gets (`_asRpcStatus`) uses
`ClientException.message`, which has none, which is why the error itself
was clean.

## Fix

- The log record carries `_asRpcStatus(e, ...)`, the same object the call
  is failed with, instead of the raw exception (the stack trace is kept).
- `health()` and `reconnect()` report `_shownBaseUrl`: `baseUrl` with its
  userinfo removed (`Uri.replace(userInfo: '')`).

## After

```
  refused    no / 0 of 1 / no
  closed     no / 0 of 1 / no
  health().details['baseUrl'] == 'http://127.0.0.1:1/base'
```

Witness `test/a_failed_request_logs_no_credentials_test.dart` (two tests).

## Canary

1. `error: 1 > 0 ? e : failure`: the log witness fails, `Expected: empty
   Actual: [... uri=http://user:pw-secret@127.0.0.1:57367/Svc/m ...]`.
2. `'baseUrl': 1 > 0 ? _baseUrl : _shownBaseUrl`: the health witness fails,
   `Expected: 'http://127.0.0.1:1/base' Actual:
   'http://user:pw-secret@127.0.0.1:1/base'`.

Restored.

## The verdict questions

1. Only the failure differs between rows; the control is the refused row,
   whose message has no uri.
2. Yes: 1 record against 0.
3. In the transport's own log stream and its health details.
4. n/a.
5. Quoted.
6. Two halves, two canaries.
7. From the numbers.
8. none.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze` green; the http suite +252; `web_smoke_test` on node.

## Siblings

- websocket: round 815 (the connect message); its health details carry no url
- http2: n/a, `connect` takes a host and a port, no userinfo
- http: fixed here
- isolate, wasm, channel: n/a, no url

## Not fixed

none.

CHANGELOG line: "rpc_dart_http: a failed request is logged with its status
instead of the raw exception, and `health()` shows `baseUrl` without its
userinfo, so a password in `baseUrl` no longer reaches logs or health
details."

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Round
`815-a-failed-connect-keeps-its-credentials.md`.
