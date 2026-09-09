# Checks on the skill itself

> Back to [SKILL.md](../SKILL.md). Run these after changing `SKILL.md`,
> [methods/](../methods/METHODS.md) or [references/](../references/REFERENCES.md)
> — they are what says the change did not regress the process.

`evals.json` holds thirteen scenarios, each derived either from a rule the methods
mark as paid for by a mistake, or from machinery added to the skill (the review,
benches, lessons, stopping from `/loop`, packs, script detectors, the continuation tier, the shortlist). Run them
through skill-creator or by hand: give an agent the skill and a fixture
repository, and compare against `expected_output`. The skill counts as
regressed if even one scenario produces a different outcome.
