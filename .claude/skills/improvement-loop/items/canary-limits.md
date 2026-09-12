---
needs: byte-limits
---

A1. For a new limit, both neighbours of the right charge point are usually
    wrong — canary those too. The tests must fail DIFFERENTLY for each wrong
    choice.
A2. The bound and the release are canaried separately: a bound that is never
    released still stops the attack, and the attack witness stays green.
