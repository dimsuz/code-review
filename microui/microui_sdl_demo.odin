package microui

import "core:fmt"
import "core:c"
import "core:runtime"
import "core:strings"
import "core:encoding/json"
import "core:time"
import SDL "vendor:sdl2"
import mu "vendor:microui"
import "curl"

WINDOW_WIDTH :: 960
WINDOW_HEIGHT :: 540

PROJECT_ID :: "1"
PRIVATE_TOKEN :: "1"

@(deferred_in_out=print_duration)
scoped_measure_duration :: proc(label: string) -> time.Tick {
  return time.tick_now()
}

print_duration :: proc(label: string, start: time.Tick) {
  duration := time.tick_since(start)
  fmt.println(label, duration)
}

state := struct {
  mu_ctx: mu.Context,
  log_buf:         [1<<16]byte,
  log_buf_len:     int,
  log_buf_updated: bool,
  bg: mu.Color,

  curl_handle: rawptr,
  mr_list: [dynamic]MergeRequest,
  current_mr_index: int,
  fetch_mr_cache: map[u32]Changes,

  atlas_texture: ^SDL.Texture,
}{
  bg = {90, 95, 100, 255},
  current_mr_index = -1
}

build_response :: proc "cdecl" (data: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
  context = runtime.default_context()
  strings.write_bytes((^strings.Builder)(userdata), data[:size * nmemb])
  return size * nmemb
}

User :: struct {
  id: int,
  username: string,
  name: string,
  avatar_url: string
}

MergeRequest :: struct {
  title: string,
  description: string,
  id: u32,
  iid: u32,
  project_id: u32,
  // author: User
}

Changes :: struct {
  old_path: []string,
  new_path: []string,
  new_file: []bool,
  diff: []string,
}

make_changes :: proc(count: int) -> Changes {
  return Changes{
    old_path = make([]string, count),
    new_path = make([]string, count),
    new_file = make([]bool, count),
    diff = make([]string, count),
  }
}

destroy_changes :: proc(value: Changes) {
  delete(value.old_path)
  delete(value.new_path)
  delete(value.new_file)
  delete(value.diff)
}

Parse_Error :: enum {
  None,
  Error
}

parse_merge_requests :: proc(response: []u8, merge_requests: ^[dynamic]MergeRequest) -> (err: Parse_Error) {
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

fetch_mr :: proc(iid: u32) -> (changes: Changes, err: Parse_Error) {
  url := fmt.tprintf("https://gitlab.com/api/v4/projects/%s/merge_requests/%d/changes?private_token=%s", PROJECT_ID, iid, PRIVATE_TOKEN)
  response := perform_get_request(url)
  defer delete(response)
  return parse_mr_changes(response)
}

perform_get_request :: proc(url: string) -> (response: []u8) {
  scoped_measure_duration(fmt.tprintf("perform GET %s: ", url))
  curl_handle := state.curl_handle
  curl.easy_setopt(curl_handle, .URL, url)
  curl.easy_setopt(curl_handle, .WRITEFUNCTION, build_response)
  resp_builder := strings.builder_make_none()
  curl.easy_setopt(curl_handle, .WRITEDATA, &resp_builder)
  curl.easy_perform(curl_handle)
  return resp_builder.buf[:]
}

main_microui :: proc() {

  state.curl_handle = curl.easy_init()
  defer curl.easy_cleanup(state.curl_handle)
  state.fetch_mr_cache = make(map[u32]Changes)
  defer delete(state.fetch_mr_cache)

  url := fmt.tprintf("https://gitlab.com/api/v4/projects/%s/merge_requests?state=opened&private_token=%s", PROJECT_ID, PRIVATE_TOKEN)
  response := perform_get_request(url)
  defer delete(response)

  parse_merge_requests(response, &state.mr_list)
  defer delete(state.mr_list)

  if err := SDL.Init({.VIDEO}); err != 0 {
    fmt.eprintln(err)
    return
  }
  defer SDL.Quit()

  window := SDL.CreateWindow("microui-odin", SDL.WINDOWPOS_UNDEFINED, SDL.WINDOWPOS_UNDEFINED, WINDOW_WIDTH, WINDOW_HEIGHT, {.SHOWN, .RESIZABLE})
  if window == nil {
    fmt.eprintln(SDL.GetError())
    return
  }
  defer SDL.DestroyWindow(window)

  backend_idx: i32 = -1
  if n := SDL.GetNumRenderDrivers(); n <= 0 {
    fmt.eprintln("No render drivers available")
    return
  } else {
    for i in 0..<n {
      info: SDL.RendererInfo
      if err := SDL.GetRenderDriverInfo(i, &info); err == 0 {
        // NOTE(bill): "direct3d" seems to not work correctly
        if info.name == "opengl" {
          backend_idx = i
          break
        }
      }
    }
  }

  renderer := SDL.CreateRenderer(window, backend_idx, {.ACCELERATED, .PRESENTVSYNC})
  if renderer == nil {
    fmt.eprintln("SDL.CreateRenderer:", SDL.GetError())
    return
  }
  defer SDL.DestroyRenderer(renderer)

  state.atlas_texture = SDL.CreateTexture(renderer, u32(SDL.PixelFormatEnum.RGBA32), .TARGET, mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT)
  assert(state.atlas_texture != nil)
  if err := SDL.SetTextureBlendMode(state.atlas_texture, .BLEND); err != 0 {
    fmt.eprintln("SDL.SetTextureBlendMode:", err)
    return
  }

  pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH*mu.DEFAULT_ATLAS_HEIGHT)
  for alpha, i in mu.default_atlas_alpha {
    pixels[i].rgb = 0xff
    pixels[i].a   = alpha
  }

  if err := SDL.UpdateTexture(state.atlas_texture, nil, raw_data(pixels), 4*mu.DEFAULT_ATLAS_WIDTH); err != 0 {
    fmt.eprintln("SDL.UpdateTexture:", err)
    return
  }

  ctx := &state.mu_ctx
  mu.init(ctx)

  ctx.text_width = mu.default_atlas_text_width
  ctx.text_height = mu.default_atlas_text_height

  main_loop: for {
    for e: SDL.Event; SDL.PollEvent(&e); /**/ {
      #partial switch e.type {
        case .QUIT:
        break main_loop
        case .MOUSEMOTION:
        mu.input_mouse_move(ctx, e.motion.x, e.motion.y)
        case .MOUSEWHEEL:
        mu.input_scroll(ctx, e.wheel.x * 30, e.wheel.y * -30)
        case .TEXTINPUT:
        mu.input_text(ctx, string(cstring(&e.text.text[0])))

        case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
        fn := mu.input_mouse_down if e.type == .MOUSEBUTTONDOWN else mu.input_mouse_up
        switch e.button.button {
        case SDL.BUTTON_LEFT:   fn(ctx, e.button.x, e.button.y, .LEFT)
        case SDL.BUTTON_MIDDLE: fn(ctx, e.button.x, e.button.y, .MIDDLE)
        case SDL.BUTTON_RIGHT:  fn(ctx, e.button.x, e.button.y, .RIGHT)
        }

        case .KEYDOWN, .KEYUP:
        if e.type == .KEYUP && e.key.keysym.sym == .ESCAPE {
          SDL.PushEvent(&SDL.Event{type = .QUIT})
        }

        fn := mu.input_key_down if e.type == .KEYDOWN else mu.input_key_up

        #partial switch e.key.keysym.sym {
          case .LSHIFT:    fn(ctx, .SHIFT)
          case .RSHIFT:    fn(ctx, .SHIFT)
          case .LCTRL:     fn(ctx, .CTRL)
          case .RCTRL:     fn(ctx, .CTRL)
          case .LALT:      fn(ctx, .ALT)
          case .RALT:      fn(ctx, .ALT)
          case .RETURN:    fn(ctx, .RETURN)
          case .KP_ENTER:  fn(ctx, .RETURN)
          case .BACKSPACE: fn(ctx, .BACKSPACE)
        }
      }
    }

    mu.begin(ctx)
    cr_windows(ctx)
    //all_windows(ctx)
    mu.end(ctx)

    render(ctx, renderer)
  }
}

render :: proc(ctx: ^mu.Context, renderer: ^SDL.Renderer) {
  render_texture :: proc(renderer: ^SDL.Renderer, dst: ^SDL.Rect, src: mu.Rect, color: mu.Color) {
    dst.w = src.w
    dst.h = src.h

    SDL.SetTextureAlphaMod(state.atlas_texture, color.a)
    SDL.SetTextureColorMod(state.atlas_texture, color.r, color.g, color.b)
    SDL.RenderCopy(renderer, state.atlas_texture, &SDL.Rect{src.x, src.y, src.w, src.h}, dst)
  }

  viewport_rect := &SDL.Rect{}
  SDL.GetRendererOutputSize(renderer, &viewport_rect.w, &viewport_rect.h)
  SDL.RenderSetViewport(renderer, viewport_rect)
  SDL.RenderSetClipRect(renderer, viewport_rect)
  SDL.SetRenderDrawColor(renderer, state.bg.r, state.bg.g, state.bg.b, state.bg.a)
  SDL.RenderClear(renderer)

  command_backing: ^mu.Command
  for variant in mu.next_command_iterator(ctx, &command_backing) {
    switch cmd in variant {
    case ^mu.Command_Text:
      dst := SDL.Rect{cmd.pos.x, cmd.pos.y, 0, 0}
      for ch in cmd.str do if ch&0xc0 != 0x80 {
        r := min(int(ch), 127)
        src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
        render_texture(renderer, &dst, src, cmd.color)
        dst.x += dst.w
      }
    case ^mu.Command_Rect:
      SDL.SetRenderDrawColor(renderer, cmd.color.r, cmd.color.g, cmd.color.b, cmd.color.a)
      SDL.RenderFillRect(renderer, &SDL.Rect{cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h})
    case ^mu.Command_Icon:
      src := mu.default_atlas[cmd.id]
      x := cmd.rect.x + (cmd.rect.w - src.w)/2
      y := cmd.rect.y + (cmd.rect.h - src.h)/2
      render_texture(renderer, &SDL.Rect{x, y, 0, 0}, src, cmd.color)
    case ^mu.Command_Clip:
      SDL.RenderSetClipRect(renderer, &SDL.Rect{cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h})
    case ^mu.Command_Jump:
      unreachable()
    }
  }

  SDL.RenderPresent(renderer)
}


u8_slider :: proc(ctx: ^mu.Context, val: ^u8, lo, hi: u8) -> (res: mu.Result_Set) {
  mu.push_id(ctx, uintptr(val))

  @static tmp: mu.Real
  tmp = mu.Real(val^)
  res = mu.slider(ctx, &tmp, mu.Real(lo), mu.Real(hi), 0, "%.0f", {.ALIGN_CENTER})
  val^ = u8(tmp)
  mu.pop_id(ctx)
  return
}

write_log :: proc(str: string) {
  state.log_buf_len += copy(state.log_buf[state.log_buf_len:], str)
  state.log_buf_len += copy(state.log_buf[state.log_buf_len:], "\n")
  state.log_buf_updated = true
}

read_log :: proc() -> string {
  return string(state.log_buf[:state.log_buf_len])
}
reset_log :: proc() {
  state.log_buf_updated = true
  state.log_buf_len = 0
}

cr_windows :: proc(ctx: ^mu.Context) {
  @static opts := mu.Options{.NO_CLOSE}
  if state.current_mr_index >= 0 {
    cmd_window_width : i32 = 200
    cmd_window_padding : i32 = 8
    mr := state.mr_list[state.current_mr_index]
    if mu.window(ctx, mr.title, {0, 0, WINDOW_WIDTH - cmd_window_width - cmd_window_padding, WINDOW_HEIGHT}, opts) {
      mu.layout_row(ctx, {-1})
      mu.layout_begin_column(ctx)
      mu.layout_row(ctx, {-1})
      mu.label(ctx, mr.description)
      mu.layout_end_column(ctx)
      if mr.iid not_in state.fetch_mr_cache {
        changes, err := fetch_mr(mr.iid)
        state.fetch_mr_cache[mr.iid] = changes
      }
      if changes, ok := state.fetch_mr_cache[mr.iid]; ok {
        mu.layout_row(ctx, {-1})
        mu.layout_begin_column(ctx)
        for diff, i in changes.diff {
            mu.layout_row(ctx, {-1})
          mu.text(ctx, diff)
        // mu.layout_begin_column(ctx)
        //     mu.layout_row(ctx, {-1}, -1)
        //     mu.button(ctx, "hello")
        //     mu.layout_row(ctx, {-1}, -1)
        //     mu.button(ctx, "hello 2")
        // mu.layout_end_column(ctx)
        }
        mu.layout_end_column(ctx)
      }
    }
    if mu.window(ctx, "Actions", {WINDOW_WIDTH - cmd_window_width, 0, cmd_window_width, WINDOW_HEIGHT}, opts) {
      mu.layout_row(ctx, {-1})
      mu.layout_begin_column(ctx)
      mu.layout_row(ctx, {-1})
      if .SUBMIT in mu.button(ctx, "MR LIST") {
        state.current_mr_index = -1
      }
      mu.layout_row(ctx, {-1})
      if .SUBMIT in mu.button(ctx, "APPROVE") {
      }
      mu.layout_end_column(ctx)
    }
  } else if len(state.mr_list) > 0 {
    filter_width : i32 = 200
    filter_padding : i32 = 8
    if mu.window(ctx, "Merge requests", {0, 0, WINDOW_WIDTH - filter_width - filter_padding, WINDOW_HEIGHT}, opts) {
      for mr, index in state.mr_list {
        mu.layout_row(ctx, {-1})
        if .SUBMIT in mu.button(ctx = ctx, label = mr.title, opt = {.EXPANDED}) {
          state.current_mr_index = index
        }
      }
    }
    if mu.window(ctx, "Filters", {WINDOW_WIDTH - filter_width, 0, filter_width, WINDOW_HEIGHT}, opts) {
    }
  }
}

all_windows :: proc(ctx: ^mu.Context) {
  @static opts := mu.Options{.NO_CLOSE}

  if mu.window(ctx, "Demo Window", {40, 40, 300, 450}, opts) {
    if .ACTIVE in mu.header(ctx, "Window Info") {
      win := mu.get_current_container(ctx)
      mu.layout_row(ctx, {54, -1}, 0)
      mu.label(ctx, "Position:")
      mu.label(ctx, fmt.tprintf("%d, %d", win.rect.x, win.rect.y))
      mu.label(ctx, "Size:")
      mu.label(ctx, fmt.tprintf("%d, %d", win.rect.w, win.rect.h))
    }

    if .ACTIVE in mu.header(ctx, "Window Options") {
      mu.layout_row(ctx, {120, 120, 120}, 0)
      for opt in mu.Opt {
        state := opt in opts
        if .CHANGE in mu.checkbox(ctx, fmt.tprintf("%v", opt), &state)  {
          if state {
            opts += {opt}
          } else {
            opts -= {opt}
          }
        }
      }
    }

    if .ACTIVE in mu.header(ctx, "Test Buttons", {.EXPANDED}) {
      mu.layout_row(ctx, {86, -110, -1})
      mu.label(ctx, "Test buttons 1:")
      if .SUBMIT in mu.button(ctx, "Button 1") { write_log("Pressed button 1") }
      if .SUBMIT in mu.button(ctx, "Button 2") { write_log("Pressed button 2") }
      mu.label(ctx, "Test buttons 2:")
      if .SUBMIT in mu.button(ctx, "Button 3") { write_log("Pressed button 3") }
      if .SUBMIT in mu.button(ctx, "Button 4") { write_log("Pressed button 4") }
    }

    if .ACTIVE in mu.header(ctx, "Tree and Text", {.EXPANDED}) {
      mu.layout_row(ctx, {140, -1})
      mu.layout_begin_column(ctx)
      if .ACTIVE in mu.treenode(ctx, "Test 1") {
        if .ACTIVE in mu.treenode(ctx, "Test 1a") {
          mu.label(ctx, "Hello")
          mu.label(ctx, "world")
        }
        if .ACTIVE in mu.treenode(ctx, "Test 1b") {
          if .SUBMIT in mu.button(ctx, "Button 1") { write_log("Pressed button 1") }
          if .SUBMIT in mu.button(ctx, "Button 2") { write_log("Pressed button 2") }
        }
      }
      if .ACTIVE in mu.treenode(ctx, "Test 2") {
        mu.layout_row(ctx, {53, 53})
        if .SUBMIT in mu.button(ctx, "Button 3") { write_log("Pressed button 3") }
        if .SUBMIT in mu.button(ctx, "Button 4") { write_log("Pressed button 4") }
        if .SUBMIT in mu.button(ctx, "Button 5") { write_log("Pressed button 5") }
        if .SUBMIT in mu.button(ctx, "Button 6") { write_log("Pressed button 6") }
      }
      if .ACTIVE in mu.treenode(ctx, "Test 3") {
        @static checks := [3]bool{true, false, true}
        mu.checkbox(ctx, "Checkbox 1", &checks[0])
        mu.checkbox(ctx, "Checkbox 2", &checks[1])
        mu.checkbox(ctx, "Checkbox 3", &checks[2])

      }
      mu.layout_end_column(ctx)

      mu.layout_begin_column(ctx)
      mu.layout_row(ctx, {-1})
      mu.text(ctx,
              "Lorem ipsum dolor sit amet, consectetur adipiscing "+
              "elit. Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus "+
              "ipsum, eu varius magna felis a nulla.",
             )
      mu.layout_end_column(ctx)
    }

    if .ACTIVE in mu.header(ctx, "Background Colour", {.EXPANDED}) {
      mu.layout_row(ctx, {-78, -1}, 68)
      mu.layout_begin_column(ctx)
      {
        mu.layout_row(ctx, {46, -1}, 0)
        mu.label(ctx, "Red:");   u8_slider(ctx, &state.bg.r, 0, 255)
        mu.label(ctx, "Green:"); u8_slider(ctx, &state.bg.g, 0, 255)
        mu.label(ctx, "Blue:");  u8_slider(ctx, &state.bg.b, 0, 255)
      }
      mu.layout_end_column(ctx)

      r := mu.layout_next(ctx)
      mu.draw_rect(ctx, r, state.bg)
      mu.draw_box(ctx, mu.expand_rect(r, 1), ctx.style.colors[.BORDER])
      mu.draw_control_text(ctx, fmt.tprintf("#%02x%02x%02x", state.bg.r, state.bg.g, state.bg.b), r, .TEXT, {.ALIGN_CENTER})
    }
  }

  if mu.window(ctx, "Log Window", {350, 40, 300, 200}, opts) {
    mu.layout_row(ctx, {-1}, -28)
    mu.begin_panel(ctx, "Log")
    mu.layout_row(ctx, {-1}, -1)
    mu.text(ctx, read_log())
    if state.log_buf_updated {
      panel := mu.get_current_container(ctx)
      panel.scroll.y = panel.content_size.y
      state.log_buf_updated = false
    }
    mu.end_panel(ctx)

    @static buf: [128]byte
    @static buf_len: int
    submitted := false
    mu.layout_row(ctx, {-70, -1})
    if .SUBMIT in mu.textbox(ctx, buf[:], &buf_len) {
      mu.set_focus(ctx, ctx.last_id)
      submitted = true
    }
    if .SUBMIT in mu.button(ctx, "Submit") {
      submitted = true
    }
    if submitted {
      write_log(string(buf[:buf_len]))
      buf_len = 0
    }
  }

  if mu.window(ctx, "Style Window", {350, 250, 300, 240}) {
    @static colors := [mu.Color_Type]string{
        .TEXT         = "text",
        .BORDER       = "border",
        .WINDOW_BG    = "window bg",
        .TITLE_BG     = "title bg",
        .TITLE_TEXT   = "title text",
        .PANEL_BG     = "panel bg",
        .BUTTON       = "button",
        .BUTTON_HOVER = "button hover",
        .BUTTON_FOCUS = "button focus",
        .BASE         = "base",
        .BASE_HOVER   = "base hover",
        .BASE_FOCUS   = "base focus",
        .SCROLL_BASE  = "scroll base",
        .SCROLL_THUMB = "scroll thumb",
    }

    sw := i32(f32(mu.get_current_container(ctx).body.w) * 0.14)
    mu.layout_row(ctx, {80, sw, sw, sw, sw, -1})
    for label, col in colors {
      mu.label(ctx, label)
      u8_slider(ctx, &ctx.style.colors[col].r, 0, 255)
      u8_slider(ctx, &ctx.style.colors[col].g, 0, 255)
      u8_slider(ctx, &ctx.style.colors[col].b, 0, 255)
      u8_slider(ctx, &ctx.style.colors[col].a, 0, 255)
      mu.draw_rect(ctx, mu.layout_next(ctx), ctx.style.colors[col])
    }
  }

}
