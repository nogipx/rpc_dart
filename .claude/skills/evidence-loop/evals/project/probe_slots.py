"""P-1: how many messages `submit` accepts before it refuses.

    python3 probe_slots.py             every message is FAILED
    python3 probe_slots.py --control   every message is COMPLETED

The control is the whole point: if both runs behave the same, the bench is
wrong and not the library.
"""

import sys

sys.path.insert(0, ".")
from router import Overflow, Router  # noqa: E402

control = "--control" in sys.argv
r = Router(max_pending=4)

for i in range(20):
    try:
        r.submit(f"m{i}")
    except Overflow:
        print(f"control={control} metric=refused_at_{i} in_flight={r.in_flight}")
        break
    if control:
        r.complete(f"m{i}")
    else:
        r.fail(f"m{i}", "peer went away")
else:
    print(f"control={control} metric=accepted_all_20 in_flight={r.in_flight}")
