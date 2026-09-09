---
pack: async-io
applies: one shared layer serves several call shapes or client types.
breaks: silence instead of an error.
status: confirmed
---

# U-11 — A shared producer with per-shape consumers

**A shared producer plus per-shape consumers is a matrix, not one fix.**

## Shape

The signal is added in shared code, while separate per-shape implementations
deliver it.

## Detector

From where the signal is born, walk EVERY delivery path; build a list of
«shape -> time to observation».

## Ask

Which shape has nowhere to put it?

## Evidence

38 ms, 11 ms, 6 ms — and SILENCE for 6 s from the fourth shape, whose
subscription logged and returned.
