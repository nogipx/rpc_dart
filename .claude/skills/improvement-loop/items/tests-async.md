---
needs: two-sided-protocol
---

A1. A fake server or proxy built inside a test is production code for the
    duration of that test: `stop()`, a guard after every `await`, and cleanup on
    the failure path too.
