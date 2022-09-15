package main

import "core:mem"
import "core:log"
import "core:fmt"
import "core:strings"
import "core:runtime"
import "core:sync"
import "core:thread"
import "core:time"
import "curl"

import sdl "vendor:sdl2"
import gl  "vendor:OpenGL"

import imgui "../odin-imgui"
import imgl  "../odin-imgui/impl/opengl"
import imsdl "../odin-imgui/impl/sdl"

DESIRED_GL_MAJOR_VERSION :: 4
DESIRED_GL_MINOR_VERSION :: 5

PROJECT_ID :: "1"
PRIVATE_TOKEN :: "1"

State :: struct {
  mr_list: [dynamic]MergeRequest,
  mr_changes: map[int]Changes,
  current_mr_index: int,
  screen: Screen,
  error: string,
}

Screen :: enum {
  Loading,
  Error,
  MR_List,
  MR_Changes,
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

Comment :: struct {
  line: int,
  text: string,
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

app_state : State
app_state_mutex : sync.Mutex

fetch_mr_list :: proc (_: ^thread.Thread) {
  url := fmt.tprintf("https://gitlab.com/api/v4/projects/%s/merge_requests?state=opened&private_token=%s", PROJECT_ID, PRIVATE_TOKEN)
  response := perform_get_request(url)
  defer delete(response)

  // TODO only lock while writing to mr_list, not while parsing?
  sync.mutex_lock(&app_state_mutex)
  err := parse_merge_requests(response, &app_state.mr_list)
  if err != .None {
    app_state.error = "Failed to parse MR list"
    app_state.screen = .Error
  } else {
    app_state.screen = .MR_List
  }
  sync.mutex_unlock(&app_state_mutex)
}

main :: proc() {
  logger_opts := log.Options {
      .Level,
      .Line,
      .Procedure,
  }
  context.logger = log.create_console_logger(opt = logger_opts)

  init_network()
  defer destroy_network()

  log.info("Starting SDL Example...")
  init_err := sdl.Init({.VIDEO})
  defer sdl.Quit()
  if init_err == 0 {
    log.info("Setting up the window...")
    window := sdl.CreateWindow("Code Review", 100, 100, 1280, 720, { .OPENGL, .MOUSE_FOCUS, .SHOWN, .RESIZABLE})
    if window == nil {
      log.debugf("Error during window creation: %s", sdl.GetError())
      sdl.Quit()
      return
    }
    defer sdl.DestroyWindow(window)

    log.info("Setting up the OpenGL...")
    sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, DESIRED_GL_MAJOR_VERSION)
    sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, DESIRED_GL_MINOR_VERSION)
    sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLprofile.CORE))
    sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
    sdl.GL_SetAttribute(.DEPTH_SIZE, 24)
    sdl.GL_SetAttribute(.STENCIL_SIZE, 8)
    gl_ctx := sdl.GL_CreateContext(window)
    if gl_ctx == nil {
      log.debugf("Error during window creation: %s", sdl.GetError())
      return
    }
    sdl.GL_MakeCurrent(window, gl_ctx)
    defer sdl.GL_DeleteContext(gl_ctx)
    if sdl.GL_SetSwapInterval(1) != 0 {
      log.debugf("Error during window creation: %s", sdl.GetError())
      return
    }
    gl.load_up_to(DESIRED_GL_MAJOR_VERSION, DESIRED_GL_MINOR_VERSION, sdl.gl_set_proc_address)
    gl.ClearColor(0.25, 0.25, 0.25, 1)

    app_state.screen = .Loading

    thread.create_and_start(fetch_mr_list)

    imgui_state := init_imgui_state(window)

    running := true
    show_demo_window := false
    e := sdl.Event{}
    for running {
      for sdl.PollEvent(&e) {
        imsdl.process_event(e, &imgui_state.sdl_state)
        #partial switch e.type {
          case .QUIT:
          log.info("Got SDL_QUIT event!")
          running = false

          case .KEYDOWN:
          if is_key_down(e, .ESCAPE) {
            qe := sdl.Event{}
            qe.type = .QUIT
            sdl.PushEvent(&qe)
          }
          if is_key_down(e, .TAB) {
            io := imgui.get_io()
            if io.want_capture_keyboard == false {
              show_demo_window = true
            }
          }
        }
      }

      imgui_new_frame(window, &imgui_state)
      imgui.new_frame()
      if show_demo_window do imgui.show_demo_window(&show_demo_window)

      sync.mutex_lock(&app_state_mutex)
      screen := app_state.screen
      sync.mutex_unlock(&app_state_mutex)

      switch screen {
      case .Loading:
        render_loading()
      case .Error:
        render_error(app_state.error)
      case .MR_List:
        sync.mutex_lock(&app_state_mutex)
        mr_list := app_state.mr_list[:]
        sync.mutex_unlock(&app_state_mutex)
        if index := render_mr_list(mr_list[:]); index != nil {
          thread.create_and_start_with_poly_data(index.?, fetch_mr_changes)
        }
      case .MR_Changes:
        title := app_state.mr_list[app_state.current_mr_index].title
        changes := app_state.mr_changes[app_state.current_mr_index]
        switch render_mr_changes(title, changes) {
        case .BACK:
          app_state.screen = .MR_List
        case .NONE:
        }
      }
      // text_test_window()
      // input_text_test_window()
      // misc_test_window()
      // combo_test_window()
      imgui.render()

      io := imgui.get_io()
      gl.Viewport(0, 0, i32(io.display_size.x), i32(io.display_size.y))
      gl.Scissor(0, 0, i32(io.display_size.x), i32(io.display_size.y))
      gl.Clear(gl.COLOR_BUFFER_BIT)
      imgl.imgui_render(imgui.get_draw_data(), imgui_state.opengl_state)
      sdl.GL_SwapWindow(window)
    }
    log.info("Shutting down...")

  } else {
    log.debugf("Error during SDL init: (%d)%s", init_err, sdl.GetError())
  }
}

info_overlay :: proc() {
  imgui.set_next_window_pos(imgui.Vec2{10, 10})
  imgui.set_next_window_bg_alpha(0.2)
  overlay_flags: imgui.Window_Flags = .NoDecoration |
    .AlwaysAutoResize |
    .NoSavedSettings |
    .NoFocusOnAppearing |
    .NoNav |
    .NoMove
  imgui.begin("Info", nil, overlay_flags)
  imgui.text_unformatted("Press Esc to close the application")
  imgui.text_unformatted("Press Tab to show demo window")
  imgui.end()
}

text_test_window :: proc() {
  imgui.begin("Text test")
  imgui.text("NORMAL TEXT: {}", 1)
  imgui.text_colored(imgui.Vec4{1, 0, 0, 1}, "COLORED TEXT: {}", 2)
  imgui.text_disabled("DISABLED TEXT: {}", 3)
  imgui.text_unformatted("UNFORMATTED TEXT")
  imgui.text_wrapped("WRAPPED TEXT: {}", 4)
  imgui.end()
}

input_text_test_window :: proc() {
  imgui.begin("Input text test")
  @static buf: [256]u8
  @static ok := false
  imgui.input_text("Test input", buf[:])
  imgui.input_text("Test password input", buf[:], .Password)
  if imgui.input_text("Test returns true input", buf[:], .EnterReturnsTrue) {
    ok = !ok
  }
  imgui.checkbox("OK?", &ok)
  imgui.text_wrapped("Buf content: %s", string(buf[:]))
  imgui.end()
}

misc_test_window :: proc() {
  imgui.begin("Misc tests")
  pos := imgui.get_window_pos()
  size := imgui.get_window_size()
  imgui.text("pos: {}", pos)
  imgui.text("size: {}", size)
  imgui.end()
}

combo_test_window :: proc() {
  imgui.begin("Combo tests")
  @static items := []string {"1", "2", "3"}
  @static curr_1 := i32(0)
  @static curr_2 := i32(1)
  @static curr_3 := i32(2)
  if imgui.begin_combo("begin combo", items[curr_1]) {
    for item, idx in items {
      is_selected := idx == int(curr_1)
      if imgui.selectable(item, is_selected) {
        curr_1 = i32(idx)
      }

      if is_selected {
        imgui.set_item_default_focus()
      }
    }
    defer imgui.end_combo()
  }

  imgui.combo_str_arr("combo str arr", &curr_2, items)

  item_getter : imgui.Items_Getter_Proc : proc "c" (data: rawptr, idx: i32, out_text: ^cstring) -> bool {
    context = runtime.default_context()
    items := (cast(^[]string)data)
    out_text^ = strings.clone_to_cstring(items[idx], context.temp_allocator)
    return true
  }

  imgui.combo_fn_bool_ptr("combo fn ptr", &curr_3, item_getter, &items, i32(len(items)))

  imgui.end()
}

is_key_down :: proc(e: sdl.Event, sc: sdl.Scancode) -> bool {
  return e.key.type == .KEYDOWN && e.key.keysym.scancode == sc
}

Imgui_State :: struct {
  sdl_state: imsdl.SDL_State,
  opengl_state: imgl.OpenGL_State,
}

init_imgui_state :: proc(window: ^sdl.Window) -> Imgui_State {
  using res := Imgui_State{}

  imgui.create_context()
  imgui.style_colors_dark()
  io := imgui.get_io()
  ranges : imgui.Im_Vector(imgui.Wchar)
  builder : imgui.Font_Glyph_Ranges_Builder
  imgui.font_glyph_ranges_builder_clear(&builder)
  imgui.font_glyph_ranges_builder_add_ranges(&builder, imgui.font_atlas_get_glyph_ranges_cyrillic(io.fonts))
  imgui.font_glyph_ranges_builder_build_ranges(&builder, &ranges)
  imgui.font_atlas_clear_fonts(io.fonts)
  imgui.font_atlas_add_font_from_file_ttf(io.fonts, "font/JetBrainsMonoNL-Regular.ttf", 20.0, nil, ranges.data)
  imgui.font_atlas_build(io.fonts)

  imsdl.setup_state(&res.sdl_state)

  imgl.setup_state(&res.opengl_state)

  return res
}

imgui_new_frame :: proc(window: ^sdl.Window, state: ^Imgui_State) {
  imsdl.update_display_size(window)
  imsdl.update_mouse(&state.sdl_state, window)
  imsdl.update_dt(&state.sdl_state)
}

render_loading :: proc() {
  ds := imgui.get_io().display_size
  imgui.set_next_window_pos(pos = div(ds, 2), pivot = imgui.Vec2{0.5, 0.5})
  imgui.set_next_window_bg_alpha(0.2)
  overlay_flags: imgui.Window_Flags = .NoDecoration |
    .AlwaysAutoResize |
    .NoSavedSettings |
    .NoFocusOnAppearing |
    .NoNav |
    .NoMove
  imgui.begin("Info", nil, overlay_flags)
  imgui.text_unformatted("Loading...")
  imgui.end()
}

render_error :: proc(error: string) {
  ds := imgui.get_io().display_size
  imgui.set_next_window_pos(pos = div(ds, 2), pivot = imgui.Vec2{0.5, 0.5})
  imgui.set_next_window_bg_alpha(0.2)
  overlay_flags: imgui.Window_Flags = .NoDecoration |
    .AlwaysAutoResize |
    .NoSavedSettings |
    .NoFocusOnAppearing |
    .NoNav |
    .NoMove
  imgui.begin("Error", nil, overlay_flags)
  imgui.text_unformatted(error)
  imgui.end()
}

render_mr_list :: proc(mr_list: []MergeRequest) -> (selected_index: Maybe(int)) {
  ds := imgui.get_io().display_size
  flags: imgui.Window_Flags = .NoSavedSettings |
    .NoNav |
    .NoMove |
    .NoResize |
    .NoCollapse
  imgui.set_next_window_pos(pos = imgui.Vec2{0, 0})
  imgui.set_next_window_size(ds)
  imgui.begin("Merge Requests", nil, flags)
  if imgui.begin_list_box("##mr_list", imgui.Vec2{-1, -1}) {
    for mr, index in mr_list {
      if imgui.selectable(mr.title) {
        selected_index = index
      }
    }
    imgui.end_list_box()
  }
  imgui.end()
  return
}

fetch_mr_changes :: proc(index: int) {
  sync.mutex_lock(&app_state_mutex)
  if index in app_state.mr_changes {
    app_state.screen = .MR_Changes
    app_state.current_mr_index = index
    sync.mutex_unlock(&app_state_mutex)
  } else {
    app_state.screen = .Loading
    iid := app_state.mr_list[index].iid
    sync.mutex_unlock(&app_state_mutex)

    changes_url := fmt.tprintf("https://gitlab.com/api/v4/projects/%s/merge_requests/%d/changes?private_token=%s", PROJECT_ID, iid, PRIVATE_TOKEN)
    changes_response := perform_get_request(changes_url)
    defer delete(changes_response)

    // TODO add proper pagination instead of maxing out at 100 comments
    comments_url := fmt.tprintf("https://gitlab.com/api/v4/projects/%s/merge_requests/%d/notes?per_page=100&private_token=%s", PROJECT_ID, iid, PRIVATE_TOKEN)
    comments_response := perform_get_request(comments_url)
    defer delete(comments_response)

    // TODO it seems that changes are copied: created in parse_mr_changes and then copyed upon return.
    // they can be quite memory heavy, fix this (if true)! UPD: Yes, rework them to #soa as done with comments
    changes, changes_err := parse_mr_changes(changes_response)
    // TODO figure out when to call delete_soa(comments)
    comments: #soa[dynamic]Comment
    comments_err := parse_mr_comments(comments_response, &comments)

    sync.mutex_lock(&app_state_mutex)
    if changes_err == .None && comments_err == .None {
      app_state.screen = .MR_Changes
      app_state.mr_changes[index] = changes
      app_state.current_mr_index = index
    } else {
      app_state.screen = .Error
      app_state.error = fmt.aprintf("Error Changes: %s, Error Comments: %s", changes_err, comments_err)
    }
    sync.mutex_unlock(&app_state_mutex)
  }
}

MR_Changes_Action :: enum { BACK, NONE }

render_mr_changes :: proc(title: string, changes: Changes) -> (action: MR_Changes_Action) {
  action = .NONE
  ds := imgui.get_io().display_size
  flags: imgui.Window_Flags = .NoSavedSettings |
    .NoNav |
    .NoMove |
    .NoResize |
    .NoCollapse
  imgui.set_next_window_pos(pos = imgui.Vec2{0, 0})
  imgui.set_next_window_size(ds)
  imgui.begin(title, nil, flags)
  if imgui.button("BACK") {
    action = .BACK
  }
  for i in 0..<len(changes.diff) {
    render_mr_change(i, changes)
  }
  imgui.end()
  return
}

render_mr_change :: proc (index: int, changes: Changes) {
  flags: imgui.Table_Flags = .Borders | .RowBg
  imgui.push_style_color(.TableRowBg, imgui.get_style().colors[imgui.Col.TableRowBgAlt])
  if imgui.begin_table("change", 1, flags) {
    imgui.table_next_column()
    imgui.text_unformatted(changes.diff[index])
    imgui.end_table()
  }
  imgui.pop_style_color()
}
