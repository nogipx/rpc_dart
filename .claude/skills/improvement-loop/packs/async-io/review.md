# async-io: questions for the verdict check

> [async-io](PACK.md) · appended to the core prompt in
> [references/review.md](../../references/review.md) by `loop.py review`

Appended to the prompt from `references/review.md` before the bottom line;
`loop.py review` assembles them itself.

```
A1. Do the attacker and the victim have separate policy and configuration
    objects? Name both.
A2. Is the gap under test made of latency or of volume? If of latency, does the
    bench introduce it rather than an in-memory pair?
A3. Does the refusal being treated as evidence name the control under test, and
    not a neighbouring limit that fired first?
```
