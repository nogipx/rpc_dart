# async-io: tests

Items for the `methods/tests.md` checklist.

A1. Give the side that issues the resource a higher ceiling than the side under
    test: otherwise its own limit throws first and the test says nothing about
    the other side.
A2. A fake server or proxy built inside a test is production code for the
    duration of that test: `stop()`, a guard after every `await`, and cleanup on
    the failure path too.

Below is what paid for each item.

## The ceiling of the side that issues the resource

- When a test holds resources issued by one side, give THAT side a higher
  ceiling than the side under test: otherwise its own limit throws first and the
  test says nothing about the other side.

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
