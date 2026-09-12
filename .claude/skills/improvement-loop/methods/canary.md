# A canary for every fix

1. Switch the fix off IN PLACE with `Edit` (`if (1 > 0) return;`, a raised
   ceiling, a flipped flag). Never `git stash`. If the switched-off tree does
   not compile, do a surgical canary: keep the declaration, remove the logic.
2. Run the new test. The witness fails with a real message, not with a timeout.
   The failure text goes into the commit and into the round record.
3. Restore it with `Edit`. Run again: green.
4. Name which one is the witness and which is the guard. A test that passes on
   both sides proves nothing about the defect.
5. A fix in two halves (bound and release, entry and exit) needs two canaries,
   one per half.
6. If the fix has a flag, a mode or an offset that can be set wrongly, canary
   THAT, not just the fix's absence.
7. A canary that unexpectedly passes means the test is wrong, not the code.
   Check the QUANTITY through a metric, not through an indirect consequence.
8. The other tests staying green under the canary is a virtue: the new test
   isolates the new defect.
9. If an existing test fails on the fix, read which situation it measured before
   touching it. If it names a side or a direction, the answer is a split, not a
   replacement. If it stands only on what you are removing, it was pinning the
   defect.
10. Before shipping, measure reachability: if the blast radius exceeds the
    exposure, that is for the owner — do not push it through.
11. Count your own attempts at a failing witness. Past `canaries: N` from the
    config the fix is not proven, whatever the code looks like: the verdict is
    INCONCLUSIVE, or DEFERRED with reason "bench".
12. Before the verdict, answer the questions `loop.py review` prints against
    your own record; a "no" about the canary sends you back to item 1.
