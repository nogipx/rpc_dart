# How to write a regression test that will not lie

1. Check "unbounded" by polling up to a threshold, not by counting after a fixed
   sleep. A sleep is safe only when YOUR process does the thing you await.
2. If you are waiting for zero, first wait for the rise.
3. Never compare two independently measured runs as a ratio; check both against
   one absolute bound.
4. Build a control or invisible byte in a fixture in code, not as a literal (the
   idiom is in the language item).
5. For every "this input is rejected", a paired "a valid input is not rejected".
6. Test state is an object the handler captures, not a global counter.
7. If you did not reproduce the reported failure, say so and name the path worth
   instrumenting; hardening measured defects is not a flake fix.
8. A truncated grep does not prove absence; "every place" means every layer.
