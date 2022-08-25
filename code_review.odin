package main

import SDL "vendor:sdl2"
import "core:fmt"
import "core:os"
import "imgui"

// currently taken from sdl2_opengl.odin
// GL_VERSION_MAJOR :: 3
// GL_VERSION_MINOR :: 3

main_code_review :: proc() {
  if (SDL.Init({.VIDEO, .TIMER}) < 0) {
    fmt.println("SDL Init failed")
    os.exit(1)
  }
  defer SDL.Quit()


  SDL.GL_SetAttribute(.CONTEXT_FLAGS,  0)
  SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK,  i32(SDL.GLprofile.CORE))
  SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, GL_VERSION_MAJOR)
  SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, GL_VERSION_MINOR)
  SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)
  SDL.GL_SetAttribute(.DEPTH_SIZE, 24)
  SDL.GL_SetAttribute(.STENCIL_SIZE, 8)

  windowFlags := SDL.WINDOW_OPENGL | SDL.WINDOW_RESIZABLE | SDL.WINDOW_ALLOW_HIGHDPI
  window := SDL.CreateWindow("Hello", SDL.WINDOWPOS_CENTERED, SDL.WINDOWPOS_CENTERED, 1280, 720, windowFlags)
  defer if (window != nil) {
    SDL.DestroyWindow(window)
  }
  if (window == nil) {
    fmt.println("Failed to create window")
    os.exit(1)
  }

  gl_context := SDL.GL_CreateContext(window)
  SDL.GL_MakeCurrent(window, gl_context)
  SDL.GL_SetSwapInterval(1) // Enable vsync
  defer SDL.GL_DeleteContext(gl_context)

  imgui.create_context(nil)

  renderer := SDL.CreateRenderer(window, -1, {})
  defer if (renderer != nil) {
    SDL.DestroyRenderer(renderer)
  }
  if (renderer == nil) {
    fmt.println("Failed to create renderer")
    os.exit(1)
  }

  loop: for {
    SDL.SetRenderDrawColor(renderer, 96, 128, 255, 255)
    SDL.RenderClear(renderer)
    event: SDL.Event
    for SDL.PollEvent(&event) {
      #partial switch event.type {
        case .KEYDOWN:
          #partial switch event.key.keysym.sym {
            case .ESCAPE:
              break loop
          }
        case .QUIT:
          break loop
      }
    }
    SDL.RenderPresent(renderer)
    SDL.Delay(16)
  }
}

main :: proc() {
  main_microui()
}
