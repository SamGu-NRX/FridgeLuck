/*
 * Suite A (pantry-truth) fit probe — Linux link shims.
 *
 * The vendored GRDB (apps/ios/Vendor/GRDB.swift) compiles with
 * SQLITE_ENABLE_SNAPSHOT; Debian's system libsqlite3 is built without the
 * WAL-snapshot APIs, so linking fails on sqlite3_snapshot_{open,get,free,cmp}.
 *
 * The probe exercises DatabaseQueue reads/writes and the recipe-fit SQL only;
 * GRDB's snapshot pool paths (DatabasePool/WAL snapshots) are unreachable from
 * it. These stubs satisfy the linker and abort loudly if ever invoked, so a
 * surprise dependency on snapshot behaviour cannot pass silently.
 */
#include <stdio.h>
#include <stdlib.h>

void sqlite3_snapshot_open(void) {
  fprintf(stderr, "FATAL: sqlite3_snapshot_open called; snapshot stubs are link-only\n");
  abort();
}
void sqlite3_snapshot_get(void) {
  fprintf(stderr, "FATAL: sqlite3_snapshot_get called; snapshot stubs are link-only\n");
  abort();
}
void sqlite3_snapshot_free(void) {
  fprintf(stderr, "FATAL: sqlite3_snapshot_free called; snapshot stubs are link-only\n");
  abort();
}
void sqlite3_snapshot_cmp(void) {
  fprintf(stderr, "FATAL: sqlite3_snapshot_cmp called; snapshot stubs are link-only\n");
  abort();
}
