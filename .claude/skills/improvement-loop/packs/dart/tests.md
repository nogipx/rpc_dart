# dart: tests

> [dart](PACK.md) · appended to the universal
> [methods/tests.md](../../methods/tests.md) by `loop.py next`

Dart idioms for the `methods/tests.md` checklist.

D1. Build a control character in code: `String.fromCharCode(1)`, not a literal
    and not an escape.
D2. Build integer literals above 2^53 for dart2js by parsing a string:
    otherwise the target compiler silently drops the whole file from the suite.

Below is what paid for each item.

## Literals that throw a file away

- A literal the target compiler will not accept silently drops THE WHOLE FILE
  from that target's suite — not just one check (in Dart: integer literals above
  2^53 under dart2js, which is why they are built by parsing a string).
