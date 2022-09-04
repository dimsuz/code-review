package main

import "core:fmt"
import "core:c"
import "core:runtime"
import "core:strings"
import "curl"

curl_handle: rawptr

init_network :: proc() {
  curl_handle = curl.easy_init()
}

destroy_network :: proc() {
  curl.easy_cleanup(curl_handle)
}

build_response :: proc "cdecl" (data: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
  context = runtime.default_context()
  strings.write_bytes((^strings.Builder)(userdata), data[:size * nmemb])
  return size * nmemb
}

perform_get_request :: proc(url: string) -> (response: []u8) {
  scoped_measure_duration(fmt.tprintf("perform GET %s: ", url))
  curl.easy_setopt(curl_handle, .URL, url)
  curl.easy_setopt(curl_handle, .WRITEFUNCTION, build_response)
  resp_builder := strings.builder_make_none()
  curl.easy_setopt(curl_handle, .WRITEDATA, &resp_builder)
  curl.easy_perform(curl_handle)
  return resp_builder.buf[:]
}
