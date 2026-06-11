#ifndef SQLiteBindings_h
#define SQLiteBindings_h

#include <sqlite3.h>

/// Binds UTF-8 text using SQLITE_TRANSIENT so SQLite copies bytes immediately.
int pv_sqlite_bind_text_transient(sqlite3_stmt *stmt, int index, const char *text);

/// Binds a blob using SQLITE_TRANSIENT so SQLite copies bytes immediately.
int pv_sqlite_bind_blob64_transient(sqlite3_stmt *stmt, int index, const void *bytes, sqlite3_uint64 length);

#endif /* SQLiteBindings_h */