---
needs: byte-limits
---

L1. Give the side that issues the resource a higher ceiling than the side under
    test: otherwise its own limit throws first and the test says nothing about
    the other side.
