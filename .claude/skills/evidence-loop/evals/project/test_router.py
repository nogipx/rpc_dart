import unittest

from router import Overflow, Router


class TestRouter(unittest.TestCase):
    def test_delivers_in_order(self):
        r = Router()
        for m in ("a", "b"):
            r.submit(m)
        for m in ("a", "b"):
            r.complete(m)
        self.assertEqual(r.delivered, ["a", "b"])

    def test_slot_returns_after_completion(self):
        r = Router(max_pending=2)
        r.submit("a")
        r.submit("b")
        r.complete("a")
        r.submit("c")
        self.assertEqual(r.in_flight, 2)

    def test_refuses_past_the_ceiling(self):
        r = Router(max_pending=1)
        r.submit("a")
        with self.assertRaises(Overflow):
            r.submit("b")

    def test_failure_is_recorded(self):
        r = Router()
        r.submit("a")
        r.fail("a", "peer went away")
        self.assertEqual(r.dropped, [("a", "peer went away")])


if __name__ == "__main__":
    unittest.main()
