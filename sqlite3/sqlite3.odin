package sqlite3

import "core:c"
foreign import sqlite3 "system:sqlite3"

@(link_prefix="sqlite3_")
foreign sqlite3 {
    libversion :: proc()                                    -> cstring ---
    errmsg     :: proc(db: ^connection)                     -> cstring ---

    open       :: proc(filename: cstring, db: ^^connection) -> Result ---
    close      :: proc(db: ^connection)                     -> Result ---

    exec        :: proc(db: ^connection, sql: cstring, cb: Exec_Callback, user_data: rawptr, errmsg: ^cstring)                   -> Result ---
    prepare_v2  :: proc(db: ^connection, sql: cstring, nbytes : c.int, statement: ^^statement, tail: ^cstring)                     -> Result ---
    prepare_v3  :: proc(db: ^connection, sql: cstring, nbytes : c.int, flags: PrepareFlag, statement: ^^statement, tail: ^cstring) -> Result ---

    step           :: proc(s: ^statement) -> Result ---
    reset          :: proc(s: ^statement) -> Result ---
    clear_bindings :: proc(s: ^statement) -> Result ---
    finalize       :: proc(s: ^statement) -> Result ---

    column_count  :: proc(s: ^statement)               -> Result ---
    column_blob   :: proc(s: ^statement, index: c.int) -> rawptr ---
    column_double :: proc(s: ^statement, index: c.int) -> f64 ---
    column_int    :: proc(s: ^statement, index: c.int) -> i32 ---
    column_int64  :: proc(s: ^statement, index: c.int) -> i64 ---
    column_text   :: proc(s: ^statement, index: c.int) -> cstring ---
    column_value  :: proc(s: ^statement, index: c.int) -> ^value ---

    bind_blob       :: proc(s: ^statement, index: c.int, value: rawptr, len: c.int, lifetime: c.intptr_t)    -> Result ---
    bind_blob64     :: proc(s: ^statement, index: c.int, value: rawptr, len: u64, lifetime: c.intptr_t)      -> Result ---
    bind_double     :: proc(s: ^statement, index: c.int, value: f64)                                         -> Result ---
    bind_int        :: proc(s: ^statement, index: c.int, value: c.int)                                       -> Result ---
    bind_int64      :: proc(s: ^statement, index: c.int, value: i64)                                         -> Result ---
    bind_null       :: proc(s: ^statement, index: c.int)                                                     -> Result ---
    bind_text       :: proc(s: ^statement, index: c.int, value: cstring, len: c.int, lifetime: c.intptr_t)   -> Result ---
    bind_text64     :: proc(s: ^statement, index: c.int, value: cstring, len: u64, lifetime: c.intptr_t)     -> Result ---
    bind_value      :: proc(s: ^statement, index: c.int, value: ^value)                                      -> Result ---
    bind_pointer    :: proc(s: ^statement, index: c.int, value: rawptr, type: cstring, lifetime: c.intptr_t) -> Result ---
    bind_zeroblob   :: proc(s: ^statement, index: c.int, len: c.int)                                         -> Result ---
    bind_zeroblob64 :: proc(s: ^statement, index: c.int, len: u64)                                           -> Result ---

    bind_parameter_index :: proc(s: ^statement, name: cstring) -> Result ---
    bind_parameter_count :: proc(s: ^statement)                -> Result ---

    free :: proc(p: rawptr) ---

    load_extension :: proc(db: ^connection, filename: cstring, entrypoint: cstring, errmsg: ^cstring) -> Result ---
}

connection :: struct {}
statement  :: struct {}
value      :: struct {}

Exec_Callback :: #type proc(user_data: rawptr, argc: c.int, argv: [^]cstring, col_name: [^]cstring) -> Exec_Callback_Check

Exec_Callback_Check :: enum c.int {
    // Proceed to the next row
    OK    = 0,
    // Abort the exec query
    ABORT = 1,
}

// Return codes used across the sqlite3 API
Result :: enum c.int {
    // Successful result
    OK         =  0,
    // Generic error
    ERROR      =  1,
    // Internal logic error in SQLite
    INTERNAL   =  2,
    // Access permission denied
    PERM       =  3,
    // Callback routine requested an abort
    ABORT      =  4,
    // The database file is locked
    BUSY       =  5,
    // A table in the database is locked
    LOCKED     =  6,
    // A malloc() failed
    NOMEM      =  7,
    // Attempt to write a readonly database
    READONLY   =  8,
    // Operation terminated by sqlite3_interrupt()
    INTERRUPT  =  9,
    // Some kind of disk I/O error occurred
    IOERR      = 10,
    // The database disk image is malformed
    CORRUPT    = 11,
    // Unknown opcode in sqlite3_file_control()
    NOTFOUND   = 12,
    // Insertion failed because database is full
    FULL       = 13,
    // Unable to open the database file
    CANTOPEN   = 14,
    // Database lock protocol error
    PROTOCOL   = 15,
    // Internal use only
    EMPTY      = 16,
    // The database schema changed
    SCHEMA     = 17,
    // String or BLOB exceeds size limit
    TOOBIG     = 18,
    // Abort due to constraint violation
    CONSTRAINT = 19,
    // Data type mismatch
    MISMATCH   = 20,
    // Library used incorrectly
    MISUSE     = 21,
    // Uses OS features not supported on host
    NOLFS      = 22,
    // Authorization denied
    AUTH       = 23,
    // Not used
    FORMAT     = 24,
    // 2nd parameter to sqlite3_bind out of range
    RANGE      = 25,
    // File opened that is not a database file
    NOTADB     = 26,
    // Notifications from sqlite3_log()
    NOTICE     = 27,
    // Warnings from sqlite3_log()
    WARNING    = 28,
    // sqlite3_step() has another row ready
    ROW        = 100,
    // sqlite3_step() has finished executing
    DONE       = 101,
}

PrepareFlag :: enum c.int {
    // Prepared statment hint that the statement is likely to be retained for a
    // long time and probably re-used many times. Without this flag,
    // sqlite3_prepare_v3/sqlite3_prepare16_v3 assume that the prepared statement
    // will be used just once or at most a few times and then destroyed (finalize).
    // The current implementation acts on this by avoiding use of lookaside memory.
    PERSISTENT = 0x01,
    // No-op, do not use
    NORMALIZE  = 0x02,
    // Prepared statement flag that causes the SQL compiler to return an error
    // if the statement uses any virtual tables.
    NO_VTAB    = 0x04,
}

// Lifetime indicator that the pointer passed to sqlite is constant and will
// never be moved.
LIFETIME_STATIC    :: 0
// Liftime indicator that the pointer passed to sqlite is likely to be moved,
// and sqlite should make its own private copy of the content before returning.
LIFETIME_TRANSIENT :: -1
