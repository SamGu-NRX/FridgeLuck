# fridgeluck-db-doctor

Bounded, strictly read-only inspection of FridgeLuck SQLite artifacts. Point it
at one explicitly supplied, closed SQLite file — typically a failed test
artifact — and it prints exactly one JSON structural report on stdout.

Why a separate tool: the app stack cannot do this. `AppDatabase.setup()`
(`apps/ios/Platform/Persistence/Database/AppDatabase.swift`) opens a database
and immediately runs `DatabaseMigrations.migrate(dbQueue)` on it, so inspecting
an artifact "with the app" would migrate it first. This tool never migrates,
repairs, writes or launches anything.

## Non-goals

- No domain or content validation (recipes, streaks, nutrition) — structure only.
- No repairs, no migrations, no arbitrary SQL; the database opens read-only.
- No app launch and no Swift/GRDB dependency.
- No default user-database discovery: the operator names the input path.
- No network access: offline, standard library only.

## Usage

```sh
cd tools/fridgeluck-db-doctor
python3 doctor/cli.py --input /path/to/artifact.sqlite
```

Filenames starting with a dash need the `=` form:

```sh
python3 doctor/cli.py --input=./-dash-named.sqlite
```

Exactly one JSON object is printed on stdout. The tool writes nothing to disk:
there is no output-file option, the input path is never used as an output
destination, and a missing input file is never created.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--input PATH` | required | The artifact to inspect. Read-only; never modified. |
| `--marker NAME` | none | Repeatable. Extends the expected structural tables (built-ins: `recipes`, `cooking_history`, `streaks`, `grdb_migrations`). |
| `--max-steps N` | `200000` | SQLite progress-handler steps per connection. |
| `--max-rows N` | `10000` | Maximum rows fetched by any single bounded scan. |
| `--max-seconds S` | `10.0` | Wall-clock deadline for the whole inspection. |

Non-positive budget values (`--max-steps 0`, `--max-rows -1`, `--max-seconds 0`)
are refused before the file is touched: refusal JSON on stdout with code
`INVALID_BUDGET`, exit 2. Malformed values (for example `--max-steps abc`) and
a missing `--input` are argparse usage errors: usage text on stderr, exit 2,
no JSON.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Inspection completed inside budget, no issues found — verdict `app_compatible_candidate` or `restorable_candidate`. |
| `1` | Inspection completed inside budget, issues reported. |
| `2` | Input refused before open (refusal codes below) — or an argparse usage error (usage text on stderr, no JSON). |
| `3` | Inspection limited or cancelled: a cap was hit or a check reported `limited`. Never a pass. |
| `4` | Internal error: an unexpected failure was caught and mapped to JSON. Never a pass. |

## Refusal codes (exit 2, verdict `not_readable`)

| Code | Meaning |
|---|---|
| `INPUT_MISSING` | No file at the given path. The tool does not create it. |
| `INPUT_NOT_REGULAR_FILE` | The path is not a regular file (directory, fifo, device, ...). |
| `INPUT_SYMLINK` | The path is a symlink. Symlinks are never followed. |
| `INPUT_NOT_SQLITE` | Smaller than 32 bytes, or the 16-byte header is not `SQLite format 3`. |
| `INPUT_SIDECAR_PRESENT` | A sibling `-wal`, `-shm` or `-journal` file exists. Pending WAL/SHM/journal state is never silently ignored: a sidecar means the database was not closed cleanly, so close it properly and retry. |
| `INVALID_BUDGET` | CLI-only refusal: non-positive budget flag values (see Flags). |

## Verdict tiers

The verdict is a confidence ladder, not a pass/fail. Three positive tiers:

1. `structurally_readable` — a valid SQLite database that opened read-only and
   had its schema listed. This does NOT mean the file is app-compatible:
   required FridgeLuck markers may be absent or the schema may not match.
2. `app_compatible_candidate` — structurally readable plus the expected
   FridgeLuck structural markers present and the latest known migration
   applied. This does NOT mean the file is safe to restore. Restoration
   decisions belong to a human with a verified backup.
3. `restorable_candidate` — app-compatible and, additionally, clean integrity
   check, zero foreign-key violations, and nothing limited or cancelled.

Two non-tier outcomes: `readable_with_issues` (the file opened, but checks
failed or the run was limited) and `not_readable` (refused before open, exit
2). Any run that hit a cap is capped at `readable_with_issues` and exits 3 —
limited runs never pass.

## Report shape

Success report (checks abridged; `detail` carries counts and codes only — the
authoritative per-check detail keys live in `doctor/diagnostics.py`):

```json
{
  "tool": "fridgeluck-db-doctor",
  "report_version": 1,
  "input": {"basename": "artifact.sqlite", "size_bytes": 28672, "sha256_16": "1f8ac10f23cdd5bc"},
  "verdict": "restorable_candidate",
  "checks": [
    {"code": "OPEN_READ_ONLY", "status": "pass", "detail": {}},
    {"code": "HEADER_MAGIC", "status": "pass", "detail": {}},
    {"code": "INTEGRITY_CHECK", "status": "pass", "detail": {"error_count": 0}},
    {"code": "SCHEMA_FINGERPRINT", "status": "pass", "detail": {"object_count": 4}}
  ],
  "issues": [],
  "limits": {"cancelled": false, "truncated": false, "deadline_hit": false, "steps_used": 11, "steps_max": 200000},
  "fingerprint": "9d5c2f8a1e4b7063"
}
```

- `input` — basename, byte size, and the first 16 hex chars of the file's
  SHA-256. Nothing else about the file or its contents.
- `checks` — one per diagnostic; `status` is `pass`, `fail`, `limited` or
  `skipped`. Real output lists every check.
- `issues` — aggregated `{code, count}` pairs.
- `limits` — cancellation flags and step usage; any flag set, or any `limited`
  check, means exit 3.
- `fingerprint` — 16-hex schema fingerprint, or `null`.

Refusal (printed as one line):

```json
{"input": {"basename": "artifact.sqlite", "sha256_16": null, "size_bytes": 0}, "refused": {"code": "INPUT_SIDECAR_PRESENT", "detail": "pending -wal/-shm/-journal sidecar present"}, "report_version": 1, "tool": "fridgeluck-db-doctor", "verdict": "not_readable"}
```

Internal error (exit 4, one line):

```json
{"internal_error": {"code": "INTERNAL_ERROR", "error_class": "NotImplementedError"}, "report_version": 1, "tool": "fridgeluck-db-doctor", "verdict": "not_readable"}
```

## Bounding and cancellation

- Every connection gets a progress handler counting steps; hitting
  `--max-steps` or the `--max-seconds` deadline aborts the current operation
  and marks the run cancelled or deadline-hit.
- Bounded scans stop at `--max-rows` rows and report `truncated` instead of
  reading further.
- A check cut short is reported with status `limited`, the verdict is capped at
  `readable_with_issues`, and the process exits 3. Limited or cancelled runs
  are never a pass — the same file may pass later with higher limits.

## Privacy

The report contains no row values, no schema SQL text, no credentials, and no
exception text. About the input file it reveals only the basename, byte size
and the 16-hex SHA-256 prefix. Internal failures report the exception class
name only.

## Invariants

- The input file's bytes and its directory's contents are left unchanged: no
  writes, no creates, no deletes, no renames; a missing input is not created.
- Output is stdout only; the input path is never an output destination.
- Offline: no network access, no environment reads, standard library only.
- Exactly one JSON object on stdout per run.

## Examples (illustrative)

Real committed examples land under `examples/` (added by the integrator).
These invocations and their exit codes are illustrative only:

```console
$ python3 doctor/cli.py --input /tmp/fl-artifact.sqlite --marker flavor_catalog
{"tool": "fridgeluck-db-doctor", ...}   # verdict app_compatible_candidate or restorable_candidate
$ echo $?
0
```

```console
$ python3 doctor/cli.py --input /tmp/fl-artifact.sqlite   # sibling -wal present
{"refused": {"code": "INPUT_SIDECAR_PRESENT", ...}, "verdict": "not_readable", ...}
$ echo $?
2
```
