package main

import "core:fmt"
import "core:strings"
import "core:strconv"
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
  scoped_measure_duration("Parse changes: ")
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
    diff_header : Diff_Header
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
    // Probably not ok to mix json parsing and "to-domain" parsing:
    // this is done here for diff lines and diff header
    diff_lines := strings.split(strings.clone(diff), "\n")
    changes.diff[i] = diff_lines[1:]
    if header := parse_diff_header(diff_lines[0]); header != nil {
      changes.diff_header[i] = header.?
    } else {
      fmt.eprintln("Failed to parse diff header at changes i=", i)
    }
  }
  fmt.println("parsed changes", len(mr_changes))
  return changes, .None
}

// TODO rework this into a streaming parsing? a lot of stuff can be skipped here
parse_mr_comments :: proc (response: []u8, comments: ^[dynamic]Comment) -> (err: Parse_Error) {
  scoped_measure_duration("Parse MR comments: ")
  err = .Error
  json_data, parse_err := json.parse(response)
  if parse_err != .None {
    fmt.eprintln("Failed to parse json")
    fmt.eprintln("Parse_Error:", parse_err)
    fmt.eprintln(strings.clone_from_bytes(response))
    return
  }
  defer json.destroy_value(json_data)
  ok: bool
  comments_data: json.Array
  if comments_data, ok = json_data.(json.Array); !ok {
    fmt.eprintln("Expected an Array")
    return
  }
  for comment_data, i in comments_data {
    comment_obj: json.Object
    if comment_obj, ok = comment_data.(json.Object); !ok {
      fmt.eprintln("Expected an Object")
      return
    }
    system: bool
    if system, ok = comment_obj["system"].(bool); !ok || system {
      continue
    }
    body: string
    if body, ok = comment_obj["body"].(string); !ok {
      fmt.eprintln("Expected a string at comments i=", i)
    }
    // TODO support "non-diff" comments, which are general comments under MR
    position_data: json.Object
    if position_data, ok = comment_obj["position"].(json.Object); !ok {
      fmt.eprintln("No position for comment i=", i)
    }
    old_line: f64
    if old_line, ok = position_data["old_line"].(f64); !ok {
      fmt.eprintln("Expected an int at comments i=", i)
    }
    new_line: f64
    if new_line, ok = position_data["new_line"].(f64); !ok {
      fmt.eprintln("Expected an int at comments i=", i)
    }
    old_path: string
    if old_path, ok = position_data["old_path"].(string); !ok {
      fmt.eprintln("Expected an old path string at comments i=", i)
    }
    new_path: string
    if new_path, ok = position_data["new_path"].(string); !ok {
      fmt.eprintln("Expected an new path string at comments i=", i)
    }
    append_elem(
      comments,
      Comment{
        text = strings.clone(body),
        old_path = strings.clone(old_path),
        new_path = strings.clone(new_path),
        old_line = (int)(old_line),
        new_line = (int)(new_line),
      }
    )
  }
  fmt.println("found comments", len(comments))
  return .None
}

parse_diff_header :: proc (raw_header: string) -> Maybe(Diff_Header) {
  header := raw_header[3:len(raw_header)-3]
  sep_index := strings.index(header, " ")
  if sep_index == -1 {
    return nil
  }
  old_l := header[1:sep_index]
  new_l := header[sep_index + 2:]
  old_l_sep_idx := strings.index(old_l, ",")
  new_l_sep_idx := strings.index(new_l, ",")
  return Diff_Header{
    old_line_start = strconv.atoi(old_l[:old_l_sep_idx]),
    old_line_count = strconv.atoi(old_l[old_l_sep_idx+1:]),
    new_line_start = strconv.atoi(new_l[:new_l_sep_idx]),
    new_line_count = strconv.atoi(new_l[new_l_sep_idx+1:]),
  }
}
