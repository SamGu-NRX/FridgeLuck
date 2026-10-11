# experiment-capsules

Independently verifiable provenance for food-study tables: a reviewer can
confirm **what produced a table** — which code, which inputs, which
model/transport settings, which outputs — **without rerunning a model** and
**without trusting current HEAD**.

A *capsule* is a directory containing a `binding.json` (the claim) and an
`outputs/` directory (immutable copies of what was produced). The binding
declares:

- **(a) exact source/import files** it depends on, each with a sha256
  content digest,
- **(b) the toolchain** (language, runtime version, external dependencies),
- **(c) permitted input references** — the only data the study may read,
- **(d) model/transport settings** that produced the outputs (for offline
  deterministic studies: `offline-deterministic`, no model, no network),
- **(e) immutable output digests**, and
- **coverage gaps**: dynamic imports that cannot be resolved statically,
  declared explicitly, never guessed as closed.

## Status / layout

| milestone | delivered |
|---|---|
| M1 | binding schema (`capsule_model.py`), static import scanner (`import_scan.py`), volatile-content scanner (`volatile_scan.py`), contract checker (`check_contract.py`), fixture contracts, pytest suite |
| M2 | read-only pack/verify adapter (`pack.py`, `verify.py`, `specs.json`) over owners' public artifacts; fixture capsules under `results/`; verification report under `reports/` |
| M3 | regeneration proof (`regen.py`) — food-study table rebuilt from capsule-stored outputs |

## The three rejection classes

`check_contract.py` rejects a binding when:

1. **missing-import** — a declared source/import file is absent from the
   repository.
2. **source-mismatch** — a file's content differs from its declared digest
   (applies to declared sources/imports and to declared outputs).
3. **self-referential-hash** — an output's declared digest string appears
   inside that output's content. No digest can be simultaneously correct and
   embedded in the content it covers (that would be a sha256 fixed point),
   so such a binding is unverifiable by construction: the classic cause is a
   generator that hashes content, appends a `# output_sha256: <digest>`
   footer, and declares the pre-embed digest for the finished file.

Additional documented strictness: `schema` (unknown fields, volatile fields
such as `generated_at`/`head`, credential-shaped fields such as `api_key`,
path traversal), `missing-output`, `undeclared-import` (a statically
resolvable local import that the binding does not declare),
`undeclared-dynamic-import` (a dynamic import construct without a declared
coverage gap), `undeclared-dependency` (a non-stdlib external import not
declared in `toolchain.dependencies`), and `source-syntax`.

Precedence per file: missing beats mismatch; a self-referential output is
reported exactly once (the implied mismatch is not double-counted).

## Packing and verifying capsules (M2)

`pack.py` adapts existing **owners' public artifacts** (today: the USDA data
studies under `scripts/data/` and the bundled Swift export they publish) into
capsules under `results/`. It reads owner files and computes digests; it
never writes anything outside `--out`, never overwrites an owner's manifest,
never reads the environment, and never calls any owner's live endpoint (the
tooling imports no network module and never executes owner code). Packing is
refused unless the spec's declared `language_version` matches the running
interpreter and the spec's sources are import-closed — the packer never
emits a binding the contract checker would reject.

```bash
python3 tools/experiment-capsules/pack.py \
    --spec tools/experiment-capsules/specs.json \
    --out tools/experiment-capsules/results

python3 tools/experiment-capsules/verify.py \
    --capsules tools/experiment-capsules/results
```

`verify.py` re-checks, per capsule: dependency digests (declared
sources/imports hashed against the current repository tree — drift is
reported, never silently accepted), import coverage (same scanner as the
checker), and output digests **from what was packed** (each stored copy in
`outputs/` is hashed against the binding). Owner artifacts that moved on
after packing are reported as **origin drift — informational, not a
rejection**: the capsule pins what was packed; output integrity is judged
against the packed copy.

Capsule layout rule (no hidden labels): a capsule directory contains only
`binding.json` and `outputs/`. Extra entries are `capsule-layout` findings;
stored files the binding does not declare are `undeclared-output` findings;
declared outputs missing their `stored_as` copy are `missing-storage`
findings. Verification evidence is committed as a timestamp-free,
digest-stable JSON report at `reports/verify-report.json` (reproduce with
`verify.py --capsules tools/experiment-capsules/results --report <path>`;
it is byte-identical on a clean tree).

Re-packing is digest-stable: the same spec, files, and interpreter produce
byte-identical capsules (bindings serialize canonically; no wall-clock or
HEAD values enter a binding).

## Regeneration proof (M3)

```bash
python3 tools/experiment-capsules/regen.py \
    --capsules tools/experiment-capsules/results \
    --out tools/experiment-capsules/reports/regen-proof
```

`regen.py` proves report regeneration **from capsule-stored outputs alone**:
it first requires the capsules to verify clean, then rebuilds the
food-study table (per-category ingredient counts and macro-completeness
shares) purely from the packed catalog copy — owner files are not read for
the table, owner code is never executed, and no live endpoint is contacted.
The volatile `generated_at_utc` field of the origin artifact is deliberately
not carried into regenerated table content; the table is rebuilt twice and
must be byte-identical, and the volatile-content scanner must find nothing
in it.

Every comparison in the committed proof (`reports/regen-proof/regen-proof.md`
plus `table-from-capsule.tsv`, both timestamp-free and digest-stable) is a
**labeled** result:

- `AGREEMENT (numerical)` — numbers match today; this is **never** identical
  provenance (the table's provenance is the packed output digests).
- `DIFFERENCE [...]` — a divergence between capsule-derived and
  origin-derived tables, or between the two capsule-stored artifacts, is
  listed explicitly. The committed proof carries one: the Swift export's
  `ingredientCount` (50, internally consistent with its 50 embedded
  records) differs from the capsule catalog's 800 records — the two owner
  artifacts cover different record sets; no equality claim is made.

Dynamic imports that cannot be statically resolved remain declared coverage
gaps in the capsule; regeneration never guesses them closed.

## Volatility policy

Wall-clock time and HEAD commit shas must stay **out of regenerated table
content** so regeneration is digest-stable. Bindings reject volatile field
names at the schema; `volatile_scan.py` scans generated content for
git-sha-like tokens (40 hex), ISO datetimes, and epoch seconds — while never
flagging 64-hex sha256 digests (legitimate in reports), plain dates that are
study data, or run ids like `r1`.

## Usage

```bash
# run every fixture case and print exact rejection counts (exit 0 = as expected)
python3 tools/experiment-capsules/check_contract.py

# check one binding (exit 0 clean / 1 rejections / 2 usage)
python3 tools/experiment-capsules/check_contract.py --binding <binding.json>

# full test suite
python3 -m pytest tools/experiment-capsules/tests -q
```

Fixture cases under `fixtures/contracts/` pin the checker's behavior:
`valid` (0 findings), `missing-import` (1), `source-mismatch` (1),
`self-referential` (1), `dynamic-gap-declared` (0 — a dynamic import with a
declared coverage gap is accepted).

## Binding paths

All paths in a binding are repository-root-relative POSIX paths. Tools
resolve the repo root from their own location; no binding may contain
absolute paths or `..` segments.

## Trust limits — read before trusting a capsule

Digests bind **content**, not **intent**. What the scheme proves and what
it does not:

- **Detects**: missing dependencies (declared file absent), source drift (a
  file's content no longer matches its declared digest), inconsistent
  rewrites (outputs that no longer match the digests recorded for them),
  digest-embedding bugs, and import-coverage holes (undeclared local or
  dynamic imports).
- **Does NOT detect**: a *consistent* malicious rewrite. An attacker who
  controls the environment can rewrite sources, outputs, and all digests
  together; every check passes. **Consistent rewritten data passes without a
  trusted external root** — the scheme detects drift and inconsistent
  rewrites, but cannot detect a consistent malicious rewrite absent an
  external root of trust (a pinned digest recorded somewhere the attacker
  cannot rewrite: a signed tag, an external log, a review artifact).
- Digest equality is **numerical agreement of content**, not identity of
  provenance: two runs agreeing numerically does not make their provenance
  identical, and reports produced under this scheme must present agreement
  and difference in exactly those terms.
- `model_transport` records *settings* (mode, model name, temperature,
  seed, transport). It cannot prove what a remote model actually returned;
  for offline-deterministic capsules no model is involved at all.
- Coverage gaps are honest holes: a declared gap means static analysis
  cannot resolve those imports and nothing verifies their contents.

## Owner boundaries

The packer/verifier (M2) are read-only adapters over *other studies'* public
artifacts: no all-repository hash sweep (only declared paths are hashed, so
unrelated studies are never invalidated), no hidden labels (capsule
directories may contain only `binding.json` and `outputs/`), no raw keys
(credential-shaped field names are rejected), owners' manifests are never
overwritten (the packer writes only inside its own `--out` directory), and
no owner's live endpoint is ever called (the tools are network-free by
construction).
