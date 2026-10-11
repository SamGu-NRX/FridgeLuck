"""fridgeluck-db-doctor: bounded read-only inspection of FridgeLuck SQLite artifacts.

The app's AppDatabase opens and migrates its database immediately, so a failed
test artifact cannot be inspected with app tooling. This package is a separate,
strictly read-only diagnostic: it never migrates, repairs or writes, and it
never claims a cancelled or truncated inspection passed.
"""
__version__ = "0.1.0"
