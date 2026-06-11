#include "SQLiteBindings.h"
#include <stddef.h>

int pv_sqlite_bind_text_transient(sqlite3_stmt *stmt, int index, const char *text) {
    if (text == NULL) {
        return sqlite3_bind_null(stmt, index);
    }
    return sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT);
}

int pv_sqlite_bind_blob64_transient(sqlite3_stmt *stmt, int index, const void *bytes, sqlite3_uint64 length) {
    if (bytes == NULL || length == 0) {
        return sqlite3_bind_null(stmt, index);
    }
    return sqlite3_bind_blob64(stmt, index, bytes, length, SQLITE_TRANSIENT);
}