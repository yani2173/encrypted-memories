// This library runs only in the historical recording process.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replace; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(replacement), (const void *)(original) }

static pthread_mutex_t mutex;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static _Thread_local bool copying;
static _Thread_local bool in_vfs;
static _Thread_local const char *rename_source;
static unsigned long sequence;
static const char *root, *output;
static void initialize(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    root = getenv("UPGRADE_RECORD_ROOT");
    output = getenv("UPGRADE_RECORD_OUTPUT");
}
static void fail(const char *operation) {
    perror(operation);
    _exit(70);
}
static bool observed(const char *name) {
    if (!root || !output || !name || copying) return false;
    size_t n = strlen(root);
    return strncmp(name, root, n) == 0 && (name[n] == '/' || name[n] == 0);
}
// Short successful cache writes expose realistic partial files through the historical Foundation path.
// SQLite writes and snapshot copies keep their original sizes.
static size_t write_amount(bool record, const char *name, size_t count) {
    if (!record || in_vfs) return count;
    if (strstr(name, "/Locations/") && strstr(name, ".journal.log") && count > 16) return 16;
    return (strstr(name, "/Caches/") || strstr(name, "/Temporary/")) && count > 4096 ? 4096 : count;
}
static bool observed_fd(int fd, char *name) {
    return fcntl(fd, F_GETPATH, name) == 0 && observed(name);
}
// Capture never opens SQLite and never closes, checkpoints or repairs a source file.
static void copy_tree(const char *from, const char *to) {
    struct stat st;
    if (lstat(from, &st) != 0) fail("snapshot stat");
    if (S_ISDIR(st.st_mode)) {
        if (mkdir(to, st.st_mode & 0777) != 0 && errno != EEXIST) fail("snapshot directory");
        DIR *dir = opendir(from);
        if (!dir) fail("snapshot listing");
        struct dirent *entry;
        while ((entry = readdir(dir))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            char source[PATH_MAX], destination[PATH_MAX];
            if (snprintf(source, sizeof source, "%s/%s", from, entry->d_name) >= (int)sizeof source ||
                snprintf(destination, sizeof destination, "%s/%s", to, entry->d_name) >= (int)sizeof destination)
                fail("snapshot path length");
            copy_tree(source, destination);
        }
        closedir(dir);
    } else if (S_ISREG(st.st_mode)) {
        int in = open(from, O_RDONLY), out = open(to, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0777);
        if (in < 0 || out < 0) fail("snapshot open");
        char buffer[65536];
        ssize_t count;
        while ((count = read(in, buffer, sizeof buffer)) > 0) {
            ssize_t position = 0;
            while (position < count) {
                ssize_t written = write(out, buffer + position, count - position);
                if (written <= 0) fail("snapshot copy");
                position += written;
            }
        }
        if (count < 0) fail("snapshot read");
        struct timespec times[2] = {st.st_atimespec, st.st_mtimespec};
        if (futimens(out, times) != 0) fail("snapshot timestamp");
        close(in); close(out);
    } else {
        errno = EINVAL;
        fail("snapshot requires regular files");
    }
}
static void capture(const char *kind, const char *path, int frames, int threshold, int result) {
    if (!observed(path)) return;
    const char *source = rename_source && observed(rename_source) ? rename_source + strlen(root) : "";
    const char *source_location = !rename_source ? "" : source[0] ? "recorded-root" :
        strstr(rename_source, "/TemporaryItems/") ? "system-temporary" : "external";
    copying = true;
    char destination[PATH_MAX], event[PATH_MAX];
    unsigned long id = ++sequence;
    snprintf(destination, sizeof destination, "%s/%06lu", output, id);
    copy_tree(root, destination);
    char oracle_copy[PATH_MAX];
    snprintf(oracle_copy, sizeof oracle_copy, "%s/%06lu.oracle.json", output, id);
    const char *oracle = getenv("UPGRADE_RECORD_ORACLE");
    if (!oracle) fail("missing external oracle");
    copy_tree(oracle, oracle_copy);
    snprintf(event, sizeof event, "%s/events.jsonl", output);
    FILE *log = fopen(event, "a");
    if (!log) fail("snapshot event");
    // Scenario paths contain only the checked synthetic component alphabet.
    fprintf(log, "{\"id\":%lu,\"kind\":\"%s\",\"path\":\"%s\",\"frames\":%d,\"threshold\":%d,\"result\":%d,\"source\":\"%s\",\"sourceLocation\":\"%s\"}\n",
        id, kind, path + strlen(root), frames, threshold, result,
        source, source_location);
    if (fclose(log)) fail("snapshot event close");
    copying = false;
}
static ssize_t observed_write(int fd, const void *buffer, size_t size) {
    pthread_once(&once, initialize);
    if (copying) return write(fd, buffer, size);
    pthread_mutex_lock(&mutex);
    char name[PATH_MAX];
    bool record = observed_fd(fd, name);
    ssize_t result = write(fd, buffer, write_amount(record, name, size));
    int saved = errno;
    if (record && result > 0 && !in_vfs) capture("write", name, 0, 0, 0);
    pthread_mutex_unlock(&mutex);
    errno = saved;
    return result;
}
static ssize_t observed_pwrite(int fd, const void *buffer, size_t size, off_t offset) {
    pthread_once(&once, initialize);
    if (copying) return pwrite(fd, buffer, size, offset);
    pthread_mutex_lock(&mutex);
    char name[PATH_MAX];
    bool record = observed_fd(fd, name);
    ssize_t result = pwrite(fd, buffer, write_amount(record, name, size), offset);
    int saved = errno;
    if (record && result > 0 && !in_vfs) capture("pwrite", name, 0, 0, 0);
    pthread_mutex_unlock(&mutex);
    errno = saved;
    return result;
}
static int observed_rename(const char *from, const char *to) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = rename(from, to), saved = errno;
    if (result == 0) {
        rename_source = from;
        capture("rename", to, 0, 0, 0);
        rename_source = NULL;
    }
    pthread_mutex_unlock(&mutex);
    errno = saved;
    return result;
}
static int observed_unlink(const char *path) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = unlink(path), saved = errno;
    if (result == 0) capture("unlink", path, 0, 0, 0);
    pthread_mutex_unlock(&mutex);
    errno = saved;
    return result;
}
static int observed_truncate(int fd, off_t length) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    char name[PATH_MAX];
    bool record = observed_fd(fd, name);
    int result = ftruncate(fd, length), saved = errno;
    if (record && result == 0 && !in_vfs) capture("truncate", name, 0, 0, 0);
    pthread_mutex_unlock(&mutex);
    errno = saved;
    return result;
}
typedef struct { int threshold; char path[PATH_MAX]; } Connection;
static int committed(void *context, sqlite3 *db, const char *database, int frames) {
    Connection *connection = context;
    pthread_mutex_lock(&mutex);
    capture("commit", connection->path, frames, connection->threshold, 0);
    // Match SQLite's sqlite3WalDefaultHook: PASSIVE at the connection's original threshold;
    // checkpoint errors do not turn a committed transaction into a failed statement.
    if (connection->threshold > 0 && frames >= connection->threshold) {
        int result = sqlite3_wal_checkpoint(db, database);
        capture("autocheckpoint", connection->path, frames, connection->threshold, result);
    }
    pthread_mutex_unlock(&mutex);
    return SQLITE_OK;
}
void upgrade_observe_connection(sqlite3 *db) {
    pthread_once(&once, initialize);
    const char *path = sqlite3_db_filename(db, "main");
    if (!observed(path) || sqlite3_db_readonly(db, "main") != 0) return;
    Connection *connection = calloc(1, sizeof *connection);
    if (!connection) fail("observer allocation");
    snprintf(connection->path, sizeof connection->path, "%s", path);
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA wal_autocheckpoint", -1, &statement, NULL) != SQLITE_OK ||
        sqlite3_step(statement) != SQLITE_ROW) fail("observer threshold");
    connection->threshold = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
    sqlite3_wal_hook(db, committed, connection);
    // The short-lived recording process owns connection contexts until it exits.
}
INTERPOSE(observed_write, write);
INTERPOSE(observed_pwrite, pwrite);
INTERPOSE(observed_rename, rename);
INTERPOSE(observed_unlink, unlink);
INTERPOSE(observed_truncate, ftruncate);
// A delegating VFS records SQLite writes even if Apple's SQLite uses private syscall symbols.
typedef struct OpenFile {
    sqlite3_file *file;
    const sqlite3_io_methods *original;
    sqlite3_io_methods methods;
    char path[PATH_MAX];
    struct OpenFile *next;
} OpenFile;
static OpenFile *files;
static sqlite3_vfs *base_vfs;
static sqlite3_vfs recorder_vfs;

static OpenFile *find_file(sqlite3_file *file) {
    for (OpenFile *item = files; item; item = item->next) if (item->file == file) return item;
    fail("missing VFS file"); return NULL;
}
static int vfs_write(sqlite3_file *file, const void *bytes, int count, sqlite3_int64 offset) {
    pthread_mutex_lock(&mutex);
    OpenFile *item = find_file(file);
    in_vfs = true;
    int result = item->original->xWrite(file, bytes, count, offset);
    in_vfs = false;
    if (result == SQLITE_OK) capture("sqlite-write", item->path, 0, 0, result);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int vfs_truncate(sqlite3_file *file, sqlite3_int64 size) {
    pthread_mutex_lock(&mutex);
    OpenFile *item = find_file(file);
    in_vfs = true;
    int result = item->original->xTruncate(file, size);
    in_vfs = false;
    if (result == SQLITE_OK) capture("sqlite-truncate", item->path, 0, 0, result);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int vfs_close(sqlite3_file *file) {
    pthread_mutex_lock(&mutex);
    OpenFile **slot = &files;
    while (*slot && (*slot)->file != file) slot = &(*slot)->next;
    if (!*slot) fail("VFS close");
    OpenFile *item = *slot;
    *slot = item->next;
    file->pMethods = item->original;
    int result = item->original->xClose(file);
    free(item);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int vfs_open(sqlite3_vfs *vfs, const char *path, sqlite3_file *file, int flags, int *out_flags) {
    (void)vfs;
    pthread_mutex_lock(&mutex);
    int result = base_vfs->xOpen(base_vfs, path, file, flags, out_flags);
    if (result == SQLITE_OK && path && observed(path)) {
        OpenFile *item = calloc(1, sizeof *item);
        if (!item) fail("VFS allocation");
        item->file = file;
        item->original = file->pMethods;
        item->methods = *file->pMethods;
        item->methods.xWrite = vfs_write;
        item->methods.xTruncate = vfs_truncate;
        item->methods.xClose = vfs_close;
        snprintf(item->path, sizeof item->path, "%s", path);
        item->next = files; files = item;
        file->pMethods = &item->methods;
    }
    pthread_mutex_unlock(&mutex);
    return result;
}
__attribute__((constructor)) static void register_vfs(void) {
    pthread_once(&once, initialize);
    if (!root || !output) return;
    base_vfs = sqlite3_vfs_find(NULL);
    if (!base_vfs) fail("system VFS");
    recorder_vfs = *base_vfs;
    recorder_vfs.zName = "upgrade-fixture-recorder";
    recorder_vfs.pNext = NULL;
    recorder_vfs.xOpen = vfs_open;
    if (sqlite3_vfs_register(&recorder_vfs, 1) != SQLITE_OK) fail("register VFS");
}
// Serial workload plus statement locks keep mapped SHM updates from racing a copied directory.
static int observed_step(sqlite3_stmt *statement) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_step(statement);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *context, char **error) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_exec(db, sql, callback, context, error);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_open(const char *name, sqlite3 **db, int flags, const char *vfs) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_open_v2(name, db, flags, vfs);
    if (result == SQLITE_OK) upgrade_observe_connection(*db);
    pthread_mutex_unlock(&mutex);
    return result;
}
#include <sys/uio.h>
extern ssize_t write_nocancel(int, const void *, size_t) __asm("_write$NOCANCEL");
extern ssize_t pwrite_nocancel(int, const void *, size_t, off_t) __asm("_pwrite$NOCANCEL");
static ssize_t observed_write_nocancel(int fd, const void *bytes, size_t count) {
    pthread_once(&once, initialize);
    if (copying) return write_nocancel(fd, bytes, count);
    pthread_mutex_lock(&mutex);
    char path[PATH_MAX]; bool record = observed_fd(fd, path);
    ssize_t result = write_nocancel(fd, bytes, write_amount(record, path, count)); int saved = errno;
    if (record && result > 0 && !in_vfs) capture("write-nocancel", path, 0, 0, 0);
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
static ssize_t observed_pwrite_nocancel(int fd, const void *bytes, size_t count, off_t offset) {
    pthread_once(&once, initialize);
    if (copying) return pwrite_nocancel(fd, bytes, count, offset);
    pthread_mutex_lock(&mutex);
    char path[PATH_MAX]; bool record = observed_fd(fd, path);
    ssize_t result = pwrite_nocancel(fd, bytes, write_amount(record, path, count), offset); int saved = errno;
    if (record && result > 0 && !in_vfs) capture("pwrite-nocancel", path, 0, 0, 0);
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
static ssize_t observed_writev(int fd, const struct iovec *iov, int count) {
    pthread_once(&once, initialize);
    if (copying) return writev(fd, iov, count);
    pthread_mutex_lock(&mutex);
    char path[PATH_MAX]; bool record = observed_fd(fd, path);
    ssize_t result = writev(fd, iov, count); int saved = errno;
    if (record && result > 0 && !in_vfs) capture("writev", path, 0, 0, 0);
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
INTERPOSE(observed_step, sqlite3_step);
INTERPOSE(observed_exec, sqlite3_exec);
INTERPOSE(observed_open, sqlite3_open_v2);
INTERPOSE(observed_write_nocancel, write_nocancel);
INTERPOSE(observed_pwrite_nocancel, pwrite_nocancel);
INTERPOSE(observed_writev, writev);

static void capture_open(const char *path, int flags, bool existed, int result) {
    if (result >= 0 && ((flags & O_TRUNC) || ((flags & O_CREAT) && !existed))) capture("create-or-truncate", path, 0, 0, 0);
}
static int observed_open_file(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list arguments; va_start(arguments, flags); mode = va_arg(arguments, int); va_end(arguments); }
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    bool existed = access(path, F_OK) == 0;
    int result = open(path, flags, mode), saved = errno;
    capture_open(path, flags, existed, result);
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
// Foundation opens some helper files with a data protection class; their creation is a boundary as well.
extern int open_dprotected_np(const char *, int, int, int, ...);
static int observed_open_protected(const char *path, int flags, int protection_class, int protection_flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list arguments; va_start(arguments, protection_flags); mode = va_arg(arguments, int); va_end(arguments); }
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    bool existed = access(path, F_OK) == 0;
    int result = open_dprotected_np(path, flags, protection_class, protection_flags, mode), saved = errno;
    capture_open(path, flags, existed, result);
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
static int observed_renamex(const char *from, const char *to, unsigned int flags) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = renamex_np(from, to, flags), saved = errno;
    if (result == 0) {
        rename_source = from;
        capture("renamex", to, 0, 0, 0);
        rename_source = NULL;
    }
    pthread_mutex_unlock(&mutex); errno = saved; return result;
}
INTERPOSE(observed_open_file, open);
INTERPOSE(observed_open_protected, open_dprotected_np);
INTERPOSE(observed_renamex, renamex_np);
// Preparation, reset, close and explicit checkpoints can also change the mapped WAL index.
static int observed_prepare(sqlite3 *db, const char *sql, int count, sqlite3_stmt **statement, const char **tail) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_prepare_v2(db, sql, count, statement, tail);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_reset(sqlite3_stmt *statement) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_reset(statement);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_finalize(sqlite3_stmt *statement) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_finalize(statement);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_close(sqlite3 *db) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_close(db);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_close_v2(sqlite3 *db) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_close_v2(db);
    pthread_mutex_unlock(&mutex);
    return result;
}
static int observed_checkpoint(sqlite3 *db, const char *name, int mode, int *frames, int *backfilled) {
    pthread_once(&once, initialize);
    pthread_mutex_lock(&mutex);
    int result = sqlite3_wal_checkpoint_v2(db, name, mode, frames, backfilled);
    pthread_mutex_unlock(&mutex);
    return result;
}
INTERPOSE(observed_prepare, sqlite3_prepare_v2);
INTERPOSE(observed_reset, sqlite3_reset);
INTERPOSE(observed_finalize, sqlite3_finalize);
INTERPOSE(observed_close, sqlite3_close);
INTERPOSE(observed_close_v2, sqlite3_close_v2);
INTERPOSE(observed_checkpoint, sqlite3_wal_checkpoint_v2);
