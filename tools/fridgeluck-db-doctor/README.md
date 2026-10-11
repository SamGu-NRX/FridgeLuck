# fridgeluck-db-doctor

Bounded, strictly read-only inspection of FridgeLuck SQLite artifacts.
**Draft skeleton** — CLI wiring and full documentation land in the next pushes.

Why: the app's `AppDatabase` opens and migrates its database immediately, so a
failed test artifact cannot be inspected with app tooling. This tool never
migrates, repairs, writes or launches the app; it reads one explicitly supplied,
closed, synthetic SQLite file and prints a machine-readable structural summary.

Status and full usage docs: see the PR description; this file is completed by
the CLI/docs stream.
