package main

import "core:fmt"
import "core:strings"
import "core:encoding/json"

Parse_Error :: enum {
  None,
  Error
}

parse_merge_requests :: proc(response: []u8, merge_requests: ^[dynamic]MergeRequest) -> (err: Parse_Error) {
  scoped_measure_duration("Parse MR list: ")
  json_data, parse_err := json.parse(response)
  if parse_err != .None {
    fmt.eprintln("Failed to parse json")
    fmt.eprintln("Parse_Error:", parse_err)
    fmt.eprintln(strings.clone_from_bytes(response))
    return .Error,
  }
  defer json.destroy_value(json_data)
  mr_list, ok := json_data.(json.Array)
  if !ok {
    fmt.eprintln("Expected an Array")
    return .Error
  }
  for mr_data in mr_list {
    mr_obj, ok := mr_data.(json.Object)
    if !ok {
      fmt.eprintln("Expected an Object")
      return .Error
    }
    mr := MergeRequest{
      title = strings.clone(mr_obj["title"].(string)),
      description = strings.clone(mr_obj["description"].(string)),
      id = u32(mr_obj["id"].(f64)),
      iid = u32(mr_obj["iid"].(f64)),
      project_id = u32(mr_obj["project_id"].(f64))
    }
    append_elem(merge_requests, mr)
  }
  return .None
}
