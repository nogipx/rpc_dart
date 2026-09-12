# What paid for the dart2js test item

> [Items](ITEMS.md) · the operative list is
> [tests-dart2js.md](tests-dart2js.md), printed by `loop.py brief` after the
> universal [methods/tests.md](../methods/tests.md)

## Literals that throw a file away

A literal the target compiler will not accept silently drops THE WHOLE FILE from
that target's suite — not just one check. In Dart that is an integer literal
above 2^53 under dart2js, which is why they are built by parsing a string.

The trait is `dart2js` and not `dart`, because a Dart project that never
compiles to JavaScript cannot hit this.
