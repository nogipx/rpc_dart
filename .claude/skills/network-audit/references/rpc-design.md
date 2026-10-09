# Design rules for an RPC ecosystem

Each rule has three parts: what mature stacks do (gRPC, AWS SDKs, Connect, Cap'n
Proto), the reason, and the question to ask of rpc_dart. Use it in `design`
mode, and whenever a public API changes. A "no" answer is a suspicion for the
evidence loop, or a feature question for the owner. It is not a finding by
itself.

Contents: 1 deadlines · 2 cancellation · 3 retries · 4 hedging and idempotency ·
5 backpressure · 6 overload · 7 error model · 8 wire and schema evolution ·
9 metadata · 10 identity · 11 connection lifecycle · 12 keepalive ·
13 observability · 14 defaults · 15 not hiding the network

## 1. Deadlines

- Set one budget at the edge. Every hop passes on what remains of it.
- On the wire the deadline is **relative** (`grpc-timeout`). Each side turns
  it into a local deadline using its own clock, so clock skew between the
  machines does not matter.
- A derived context can **shorten** the deadline, never extend it. Go's
  `context.WithDeadline` keeps whichever is earlier, the parent's or the new
  one.
- The server checks the remaining time before expensive work, and refuses an
  already-expired request without calling downstream.
- Enforce the deadline where it is read, not only where it is sent (B-108,
  B-244).

Ask:
- Does `RpcContext.withDeadline` / `withTimeout` keep the earlier of the
  parent's deadline and the new one?
- Does a handler's downstream call inherit the incoming deadline without
  extra work by the user?
- Is every local deadline on a monotonic clock?

## 2. Cancellation

- Cancelling a call reaches the handler's work and every child call, not only
  the socket.
- A cancelled call releases everything it holds on every path (C-37, C-41).
- Cancellation is not rollback. Work that already committed stays committed.

Ask:
- Can a handler see cancellation without polling: a token, a future, a closed
  stream?
- Is there a safe way to pass on the incoming context that keeps deadline and
  cancellation but drops credentials? (`RpcContext.sanitize` drops credentials,
  but it also drops the deadline and the token.)

## 3. Retries

gRPC's rules (proposal A6), plus Marc Brooker's:

- Retry only statuses that mean "not processed" or "overloaded, with
  pushback". Retry nothing after response headers arrive: that is the commit
  point.
- Exponential backoff with **full jitter**:
  `sleep = random(0, min(cap, base * 2^n))`. Without jitter, the retries of
  many clients arrive together.
- A **retry budget** (token bucket). Each failure costs 1 token and each
  success adds 0.1. Retries stop below half the bucket. Without one, retries
  multiply down the stack: 3 attempts on each of 5 layers is 3^5 = 243 times
  the load on the bottom layer.
- Server pushback (`RpcRetryInfo`, `grpc-retry-pushback-ms`) sets the delay.
  It never adds attempts and never extends the deadline.
- Backoff that does not fit in the remaining deadline means no retry
  (`RpcRetryInterceptor` already does this).

Ask:
- Is there a retry budget? Is it shared across calls to one server?
- Are streaming calls excluded? (They are: `RpcRetryInterceptor` retries
  unary only.)
- After a retry, can the client tell whether it got the first attempt's
  result or a later one? Is `requestId` stable across attempts, so the server
  can deduplicate?

## 4. Hedging and idempotency

- Hedging sends a second copy after a delay, takes the first answer, and
  cancels the rest. It is for idempotent unary calls only, with spare
  capacity, and under the same overall deadline.
- Idempotency is a server property. The client cannot get it by retrying
  carefully. The standard mechanism is a client-chosen key that is stable
  across attempts and deduplicated on the server.

Ask: is there a documented idempotency-key convention, and does the generator
let a method be marked idempotent?

## 5. Backpressure and flow control

- Credit-based flow control per stream, plus a bound per connection. The
  sender is told how much it may send.
- Every buffer has a bound in bytes **and** in messages, because the peer
  chooses the size of each message (RPC-27).
- One slow consumer stalls only its own stream (KV-WS-07).
- Pausing the consumer must reach the source, all the way down (L-07).

## 6. Overload

- Refuse at admission, cheaply, before the expensive work (load shedding).
  Do not queue without a bound.
- RESOURCE_EXHAUSTED plus retry info lets clients back off. INTERNAL tells
  them nothing.
- Concurrency limits beat rate limits for protecting a server, since they
  bound what is actually held.
- A circuit breaker that counts application errors as failures opens on
  correct behaviour (B-110). Brooker prefers token buckets to breakers: a
  breaker adds a mode that is hard to test.

## 7. Error model

- A fixed set of status codes with documented retryability. INTERNAL is
  final. UNAVAILABLE and RESOURCE_EXHAUSTED (with pushback) are retryable.
- Messages sent to the peer carry no internals. Rich details travel
  separately (`grpc-status-details-bin`).
- A refusal is itself valid protocol output, and it obeys the limits it
  enforces (RPC-02).
- A local failure ("the connection is gone") and a remote status ("the
  handler said UNAVAILABLE") are different facts, even when the code is the
  same (see `_reconnectIfConnectionIsGone`).

## 8. Wire and schema evolution

- Old clients with new servers, and new clients with old servers, both work.
  Test both directions explicitly.
- Fields are identified by stable numbers or names that are never reused.
  Adding an optional field is safe. Removing a field, renaming one, or
  changing its type is not.
- The decoder tolerates unknown fields (ignores or keeps them) and missing
  ones (defaults). Unknown enum values do not crash.
- Version the transport protocol itself: a handshake or a version header, so
  a frame format can change without guessing.

Ask: for generated codecs, what happens when the server adds a field, removes
one, or adds an enum value, and an old client decodes the response? Is there
a test for each?

## 9. Metadata

- Keys are lower-case ASCII tokens. Values are printable ASCII, and binary
  data goes in `-bin` keys, base64-encoded.
- Prefixes reserved for the framework (`grpc-`, and rpc_dart's own) cannot be
  set by users or spoofed by peers.
- Limits apply in both directions (KV-R-02).
- Hop-by-hop metadata (credentials, connection-specific keys) is not
  forwarded to the next hop by default.

## 10. Identity and auth

- Identity comes from the authenticated channel or from verified credentials
  in metadata, and it reaches the handler through the context. Never from the
  message body (KV-R-13).
- Per-call credentials are re-checked per call, and are re-sent after a
  reconnect.
- Credentials never appear in logs or error messages.

## 11. Connection lifecycle

- Graceful shutdown: stop accepting, tell peers (GOAWAY or the transport's
  equivalent), let in-flight calls finish within a budget, then close.
- Every lifecycle method is idempotent and safe to call concurrently
  (RPC-21).
- A connect has stages (TCP, TLS, upgrade, preface, ready). Each stage is
  bounded, and the call waits for "ready", not for "socket open" (RPC-28).
- Reconnect has defined semantics for calls in flight: they fail, and they
  are not silently replayed.

## 12. Keepalive

- Both sides detect a dead peer within a bounded time, even when no FIN
  arrives.
- The server has an abuse policy: a minimum ping interval, and a refusal when
  it is broken.
- Keepalive does not keep an idle connection open forever against the
  server's will (max idle, max connection age).

## 13. Observability

- Trace context propagates across hops (W3C `traceparent`; rpc_dart has
  `traceId`), and a handler's downstream calls continue the same trace.
- Metrics per method and status, with bounded cardinality: never a peer-chosen
  string as a label.
- Logs: one guarded shape (see the repo's Logging section); peer-triggered
  warnings fire once; no secrets.

## 14. Defaults

- Every limit is on by default, on client and server, on every transport.
- Insecure options are opt-in: compression, permissive CORS, disabled TLS
  verification.
- Defaults are visible: a user can read every limit's value in one place
  (`RpcSecurityPolicy`).

## 15. Do not hide the network

Waldo et al., "A Note on Distributed Computing" (1994): latency, partial
failure, concurrency and the lack of shared memory cannot be made
transparent. An API that makes a remote call look like a local one leads users
to forget deadlines, retries and idempotency.

Ask: does the generated caller API make the deadline, cancellation and
failure modes visible at the call site, rather than burying them?

## Sources

- gRPC retries, A6: https://github.com/grpc/proposal/blob/master/A6-client-retries.md
- Deadlines and cancellation: https://learn.microsoft.com/en-us/aspnet/core/grpc/deadlines-cancellation
- Brooker, timeouts and retries: https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/
- Brooker, jitter: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
- Brooker, token buckets: https://brooker.co.za/blog/2022/02/28/retries.html
- Brooker, what backoff is for: https://brooker.co.za/blog/2022/08/11/backoff.html
- Google SRE book, "Handling Overload" and "Addressing Cascading Failures"
- Waldo, Wyant, Wollrath, Kendall, "A Note on Distributed Computing", 1994
