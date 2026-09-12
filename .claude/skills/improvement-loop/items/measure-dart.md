---
needs: dart
---

D1. An unhandled error with an empty stack did not come from a throw but from
    `completeError`/`addError` with no stack — look for the completion site.
D2. A guarded zone (`runZonedGuarded`) catches only its own side's errors —
    check whose code threw.
