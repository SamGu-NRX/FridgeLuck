Suite modules committed in this directory, copied unmodified from
evaluation/suites/recipes on branch eval/scorecard-runner @ 9d3a704
(the revision the world-2026-10 packet was built against; check_packet.py
needs its CanonRulebook and FLIngredientFacts-backed claim verification):
  bands.py rs.py rights.py allergens.json canon/
The CORPUS validator (data/recipes/tools/validate_corpus.py) pins its own
suite extraction at data/recipes/suite/ (26c7004) — the corpus's authoring
revision; the two consumers must not share one revision.
