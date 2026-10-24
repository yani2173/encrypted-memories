// Compare the system autocheckpoint with the recording callback at the unchanged default threshold.
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static void require(int result) {
    if (result != SQLITE_OK && result != SQLITE_DONE) { fprintf(stderr, "SQLite proof failed: %d\n", result); exit(1); }
}
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    char path[4096], shm[4096];
    snprintf(path, sizeof path, "%s/policy.sqlite", argv[1]);
    snprintf(shm, sizeof shm, "%s/policy.sqlite-shm", argv[1]);
    sqlite3 *db = NULL;
    require(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL));
    require(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);", NULL, NULL, NULL));
    sqlite3_stmt *statement = NULL;
    require(sqlite3_prepare_v2(db, "INSERT INTO records VALUES(?, 'synthetic checkpoint proof');", -1, &statement, NULL));
    FILE *trace = fopen(argv[2], "w");
    if (!trace) return 70;
    fputs("[", trace);
    for (int i = 0; i < 1030; i++) {
        require(sqlite3_bind_int(statement, 1, i));
        require(sqlite3_step(statement));
        require(sqlite3_reset(statement));
        int file = open(shm, O_RDONLY);
        uint32_t frames = 0, backfilled = 0;
        if (file < 0 || pread(file, &frames, 4, 16) != 4 || pread(file, &backfilled, 4, 96) != 4) return 70;
        close(file);
        fprintf(trace, "%s[%d,%u,%u]", i ? "," : "", i, frames, backfilled);
    }
    fputs("]\n", trace);
    fclose(trace);
    require(sqlite3_finalize(statement));
    require(sqlite3_close(db));
    return 0;
}
