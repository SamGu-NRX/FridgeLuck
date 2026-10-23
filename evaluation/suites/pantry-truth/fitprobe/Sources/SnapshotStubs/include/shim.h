#ifndef FL_FITPROBE_SNAPSHOT_SHIM_H
#define FL_FITPROBE_SNAPSHOT_SHIM_H

/* Link-only shims for sqlite3 snapshot APIs absent from Debian libsqlite3.
 * See shim.c: each aborts loudly if ever invoked. */
void sqlite3_snapshot_open(void);
void sqlite3_snapshot_get(void);
void sqlite3_snapshot_free(void);
void sqlite3_snapshot_cmp(void);

#endif
