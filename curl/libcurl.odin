package curl

import "core:c"
foreign import lib "system:curl"

Code :: enum c.int {
  OK = 0
}

Option :: enum c.int {
  URL = 10000 /* STRINGPOINT */ + 2,
  WRITEDATA = 10000 /* CBPOINT */ + 1,
  WRITEFUNCTION = 20000 /* FUNCPOINT */ +  11
}

@(default_calling_convention="c", link_prefix="curl_")
foreign lib {
  easy_setopt :: proc(handle: rawptr, option: Option, #c_vararg params: ..any) ---
  easy_init :: proc() -> rawptr ---
  easy_cleanup :: proc(handle: rawptr) ---
  easy_perform :: proc(handle: rawptr) ---
}
