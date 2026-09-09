---
pack: core
applies: there is more than one implementation of a shared contract.
breaks: a silent hang, a silent truncation.
status: confirmed
---

# U-14 — Compare siblings; the signal versus its handling

**The absence of a defect in the handling may mean the input never arrives.**

A corollary: layers in other languages are part of the implementation. Three
sweeps in the main language could find neither the native callback feeding a
dead completion nor the `log; break` in the neighbouring language.

## Shape

Several implementations of one interface; the battery was not run against all of
them.

## Detector

One battery across every implementation at once; compare the results with each
other rather than with an expectation.

## Ask

Which one stands out? And if they are all clean — does the INPUT signal even
exist in the implementation whose handling was never checked?

## Evidence

Two implementations came back clean, and the third had no signal at all that the
other side had died, so the shared path — already working — never ran.
