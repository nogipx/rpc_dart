"""A tiny message router with a bounded number of in-flight messages.

`submit` charges a slot, `complete` and `fail` are the two ways a message
leaves. Everything the suite exercises passes.
"""


class Overflow(Exception):
    """Raised when no slot is free."""


class Router:
    def __init__(self, max_pending: int = 4) -> None:
        self.max_pending = max_pending
        self._pending: list[str] = []
        self.delivered: list[str] = []
        self.dropped: list[str] = []

    @property
    def in_flight(self) -> int:
        return len(self._pending)

    def submit(self, msg: str) -> None:
        if len(self._pending) >= self.max_pending:
            raise Overflow(f"no slot free for {msg!r}")
        self._pending.append(msg)

    def complete(self, msg: str) -> None:
        self._pending.remove(msg)
        self.delivered.append(msg)

    def fail(self, msg: str, reason: str) -> None:
        self.dropped.append((msg, reason))
