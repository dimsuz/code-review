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

parse_mr_changes :: proc(response: []u8) -> (changes: Changes, err: Parse_Error) {
  scoped_measure_duration("parsing changes: ")
  changes = make_changes(0)
  err = .Error
  json_data, parse_err := json.parse(response)
  if parse_err != .None {
    fmt.eprintln("Failed to parse json")
    fmt.eprintln("Parse_Error:", parse_err)
    return
  }
  defer json.destroy_value(json_data)
  ok: bool
  mr_obj: json.Object
  if mr_obj, ok = json_data.(json.Object); !ok {
    fmt.eprintln("Expected an Object")
    return
  }
  mr_changes: json.Array
  if mr_changes, ok = mr_obj["changes"].(json.Array); !ok {
    fmt.eprintln("Expected an Array")
    return
  }
  changes = make_changes(count = len(mr_changes))
  for json_change, i in mr_changes {
    v : json.Object
    old_path : string
    new_path : string
    new_file : bool
    diff : string
    if v, ok = json_change.(json.Object); !ok {
      fmt.eprintln("Expected an Object")
      return
    }
    if old_path, ok = v["old_path"].(string); !ok {
      fmt.eprintln("Expected a string at changes i=", i)
      return
    }
    if new_path, ok = v["new_path"].(string); !ok {
      fmt.eprintln("Expected a string at changes i=", i)
      return
    }
    if new_file, ok = v["new_file"].(bool); !ok {
      fmt.eprintln("Expected a bool at changes i=", i)
      return
    }
    if diff, ok = v["diff"].(string); !ok {
      fmt.eprintln("Expected a string at changes i=", i)
      return
    }
    changes.old_path[i] = strings.clone(old_path)
    changes.new_path[i] = strings.clone(new_path)
    changes.new_file[i] = new_file
    changes.diff[i] = strings.clone(diff)
  }
  fmt.println("parsed changes", len(mr_changes))
  return changes, .None
}
