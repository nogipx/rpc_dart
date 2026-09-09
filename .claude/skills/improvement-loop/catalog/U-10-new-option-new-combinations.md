---
pack: async-io
applies: there are two sides configured independently.
breaks: a hang, silence instead of a reply.
status: confirmed
---

# U-10 — A new option means new combinations

A fix here often needs TWO edits. **If the symptom changed after the first one
but did not improve, the second half is the delivery path, not a wrong
diagnosis.**

## Shape

A knob was added, and the other side picks its behaviour independently.

## Detector

For every option added in recent rounds, write out the matrix «our choice x the
other side's choice» and run all of it.

## Ask

Which cell of the matrix was never executed?

## Evidence

One of four combinations answered nothing for 6 s while the others answered in
10-21 ms. The silence existed before the knob; all that was new was
reachability — the usual shape of such findings.
