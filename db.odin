package main

import sqlite "sqlite3"
import "core:fmt"
import "core:strings"

DB_FILE :: "code-review.db"

@private
conn: ^sqlite.connection

@private
CREATE_COMMENTS_TABLE_STMT :: `
CREATE TABLE IF NOT EXISTS comments (
  id INTEGER PRIMARY KEY,
  mr_iid INTEGER NOT NULL,
  sha TEXT NOT NULL,
  text TEXT NOT NULL,
  old_path TEXT,
  new_path TEXT,
  old_line INTEGER,
  new_line INTEGER,
  author_name TEXT,
  updated_at TEXT
)
`

Db_Error :: enum {
  InitFailed,
  AddCommentFailed,
}

db_init :: proc () -> (err: Maybe(Db_Error)) {
  res := sqlite.open(DB_FILE, &conn)
  if res != .OK {
    fmt.eprintf("Failed to open database file %s: %s\n", DB_FILE, res)
    return .InitFailed
  }
  sqlite.exec(conn, CREATE_COMMENTS_TABLE_STMT, nil, nil, nil)
  return nil
}

@private
ADD_COMMENT_STMT : string : `
INSERT OR REPLACE INTO
comments
VALUES (%d, %d, "%s", "%s", "%s", "%s", %d, %d, "%s", "%s")
`

@private
escape_str :: proc(s: string) -> string {
  res, _ := strings.replace_all(s, "\"", "\"\"")
  return res
}

db_add_comment :: proc(
  mr_iid: u32,
  id: u32,
  sha: string,
  text: string,
  old_path: string,
  new_path: string,
  old_line: u32,
  new_line: u32,
  author_name: string,
  updated_at: string) -> Maybe(Db_Error)
{
  stmt := fmt.tprintf(
    ADD_COMMENT_STMT,
    id,
    mr_iid,
    sha,
    escape_str(text),
    escape_str(old_path),
    escape_str(new_path),
    old_line,
    new_line,
    escape_str(author_name),
    updated_at)
  err_msg: cstring
  // TODO switch to using prepared statements
  if res := sqlite.exec(conn, strings.clone_to_cstring(stmt), nil, nil, &err_msg); res != .OK {
    fmt.println(stmt)
    fmt.eprintf("Failed to add comment: %s\n", err_msg)
    sqlite.free(&err_msg)
    return .AddCommentFailed
  }
  return nil
}
