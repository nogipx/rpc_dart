# What paid for the byte-limits test item

> [Items](ITEMS.md) · the operative list is [tests-limits.md](tests-limits.md),
> printed by `loop.py brief` after the universal
> [methods/tests.md](../methods/tests.md)

## The ceiling of the side that issues the resource

When a test holds resources issued by one side, give THAT side a higher ceiling
than the side under test: otherwise its own limit throws first and the test says
nothing about the other side.
