# Mutation verification

The fixture-contract suite proves itself by failing when the thing it pins
breaks. Two deliberate faults were injected into the lab, the suite was run
against each, and both were reverted afterward (final state: 54/54 green).

## Mutation A — server wire behavior

`fixture_server.py`: truncation served the full payload instead of the
declared prefix (`self.wfile.write(content[:cut])` → `self.wfile.write(content)`).

Result: 3 failed, 51 passed.

```
FAILED tests/test_fixtures.py::test_truncation_declares_full_length_sends_prefix_then_eof
FAILED tests/test_fixtures.py::test_truncation_depth_prefix_matches_expected_record
FAILED tests/test_fixtures.py::test_interrupted_write_ends_in_rst
```

Exactly the tests that pin the truncation contract failed; nothing else
flapped. Reverted; suite returned to 54 passed.

## Mutation B — expected-byte records

`scenarios.json`: one hex character flipped in
`clean-rgb-control.expect.content_sha256` (a corrupted expected-final-byte
record, the class of error a hand-edited manifest would produce).

Result: 2 failed, 52 passed.

```
FAILED tests/test_fixtures.py::test_clean_control_serves_exact_declared_bytes
FAILED tests/test_scenario_records.py::test_expected_final_byte_records_rederive
```

Both the server contract test and the record-rederivation test caught it.
Reverted; suite returned to 54 passed.

## Replay

```bash
cd tools/acquisition-faultlab
cp fixture_server.py /tmp/fixture_server.py.bak
sed 's/self.wfile.write(content\[:cut\])/self.wfile.write(content)/' fixture_server.py > /tmp/m.py
# apply, run pytest, restore
```

The exact sequences used are preserved in the PR description for this work.
