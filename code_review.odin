package main

import "core:mem"
import "core:log"
import "core:fmt"
import "core:strings"
import "core:runtime"
import "core:sync"
import "core:slice"
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
  mr_comments: map[int]#soa[]Comment,
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
  old_path: string,
  new_path: string,
  old_line: int,
  new_line: int,
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
        comments := app_state.mr_comments[app_state.current_mr_index]
        switch render_mr_changes(title, changes, comments) {
        case .BACK:
          app_state.screen = .MR_List
        case .NONE:
        }
      }
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
      app_state.mr_comments[index] = comments[:]
      app_state.current_mr_index = index
    } else {
      app_state.screen = .Error
      app_state.error = fmt.aprintf("Error Changes: %s, Error Comments: %s", changes_err, comments_err)
    }
    sync.mutex_unlock(&app_state_mutex)
  }
}

MR_Changes_Action :: enum { BACK, NONE }

render_mr_changes :: proc(title: string, changes: Changes, comments: #soa[]Comment) -> (action: MR_Changes_Action) {
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
    // TODO use IsRectVisible to test if change is in fact required to be submitted
    render_mr_change(i, changes, comments)
  }
  imgui.end()
  return
}

callback1 :: proc "cdecl" (data: ^imgui.Input_Text_Callback_Data) -> int {
  return 0
}

render_mr_change :: proc (index: int, changes: Changes, mr_comments: #soa[]Comment) {
  flags: imgui.Table_Flags = .Borders | .RowBg
  imgui.push_style_color(.TableRowBg, imgui.get_style().colors[imgui.Col.TableRowBgAlt])
  lines := strings.split(changes.diff[index], "\n")
  old_path := changes.old_path[index]
  new_path := changes.new_path[index]

  // TODO doing this on EACH frame is bad!
  cc_old_path, cc_new_path, _, _, _ := soa_unzip(mr_comments)
  comments: map[int]Comment
  defer delete(comments)
  for i in (0..<len(mr_comments)) {
    if cc_old_path[i] == old_path && cc_new_path[i] == new_path {
      comments[mr_comments[i].new_line] = mr_comments[i]
      break
    }
  }

  if imgui.begin_table("change", 2, flags) {
    imgui.table_setup_column("action", imgui.Table_Column_Flags.WidthFixed, 32)
    for line, li in lines[1:] {
      imgui.table_next_column()
      imgui.button("v")
      imgui.table_next_column()
      imgui.text_unformatted(line)
      if c, ok := comments[li]; ok {
        if imgui.collapsing_header("Comment by dz") {
          imgui.text_wrapped(c.text)
          // imgui.input_text_multiline(label = "##reply", buf = text, buf_size = len(text), callback = callback1, flags = imgui.Input_Text_Flags(imgui.Input_Text_Flags.CallbackResize))
        }
      }
    }
    imgui.end_table()
  }
  imgui.pop_style_color()
  return
}
