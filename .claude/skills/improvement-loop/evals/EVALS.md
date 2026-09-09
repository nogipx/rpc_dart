# Checks on the skill itself

`evals.json` holds eleven scenarios, each derived either from a rule the methods
mark as paid for by a mistake, or from machinery added to the skill (the review,
benches, lessons, stopping from `/loop`, packs, script detectors). Run them
through skill-creator or by hand: give an agent the skill and a fixture
repository, and compare against `expected_output`. The skill counts as
regressed if even one scenario produces a different outcome.
