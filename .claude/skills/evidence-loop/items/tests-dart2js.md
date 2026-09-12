---
needs: dart2js
---

J1. Build integer literals above 2^53 by parsing a string: otherwise the target
    compiler silently drops the whole file from the suite.
