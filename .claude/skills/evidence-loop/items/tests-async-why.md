# What paid for the two-sided-protocol test item

> [Items](ITEMS.md) · the operative list is [tests-async.md](tests-async.md),
> printed by `loop.py brief` after the universal
> [methods/tests.md](../methods/tests.md)

## Fake servers and proxies inside a test

**A fake server or proxy assembled inside a test is production code for the
duration of that test, and it needs a `stop()`.** A test proxy paused for 400 ms
with a suspended subscription and regularly woke after `tearDown`, and the
connection it then opened threw an UNHANDLED async error
(`OS Error: Network is down`) that killed the whole process.

Any helper that waits inside a callback must:
(a) guard every step after an await,
(b) track what it opened so teardown can destroy it,
(c) run its cleanup step on the failure path too — there it is precisely the
`resume()` delivering `onDone` that destroys the upstream socket, so skipping it
leaks the very connection the test is counting.
