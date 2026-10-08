---
round: 718 (paid), 723 (paid again)
class: bench
cost: round 718 rebuilt its instrument four times before one could see the defect (a flush that never returned, a Socket forwarder, a RawSocket forwarder, a RawSocket client), the fifth was the process's socket table; round 723 lost one arm to a TCP-level deaf reader that stopped the sender too
paths: [packages/transport/*/lib/**]
commit: 472dd6af
status: active
---

# L-21 — count a socket in the process that owns it

## The rule

To learn whether this side released a socket, read this side's socket table
(`lsof -n -P -p <pid>`), not the peer. A half-close and a close put the same
FIN on the wire, so every peer-side signal reads them alike. The opposite
case is L-11: an EVENT the peer must see is asserted at the peer. A RESOURCE
this side must free is counted where it lives.

## What it cost

Round 718's forwarder read "fully closed" for a client that had only
half-closed. A peer write into it drew an RST, and a `dart:io` `Socket`
forwarder closed itself on the FIN. Four instruments, all reading the same
for the case and the control, before `lsof` read 1 against 0. Round 723
repeated the mistake in another form: a reader made deaf at the TCP level
also stopped the client's WINDOW_UPDATEs, so the sender halted and the arm
measured nothing. Deafness had to be at the h2 level.

## How to apply

Before building a bench, write down the side that owns the quantity and the
layer at which the peer misbehaves. Then instrument that side at that layer,
and validate the instrument against a control that differs only in it.
