package main

import "vendor:sdl2"
import "core:fmt"
import "core:os"

foreign import imgui "cimgui/cimgui.so"

@(default_calling_convention="c")
foreign imgui {
  igAlignTextToFramePadding          :: proc() ---;
}

main :: proc() {
  if (sdl2.Init({.VIDEO}) < 0) {
    fmt.println("SDL Init failed")
    os.exit(1)
  }
  defer sdl2.Quit()

  window := sdl2.CreateWindow("Hello", sdl2.WINDOWPOS_UNDEFINED, sdl2.WINDOWPOS_UNDEFINED, 800, 800, {})
  defer if (window != nil) {
    sdl2.DestroyWindow(window)
  }

  if (window == nil) {
    fmt.println("Failed to create window")
    os.exit(1)
  }

  renderer := sdl2.CreateRenderer(window, -1, {})
  defer if (renderer != nil) {
    sdl2.DestroyRenderer(renderer)
  }
  if (renderer == nil) {
    fmt.println("Failed to create renderer")
    os.exit(1)
  }

  loop: for {
    sdl2.SetRenderDrawColor(renderer, 96, 128, 255, 255)
    sdl2.RenderClear(renderer)
    event: sdl2.Event
    for sdl2.PollEvent(&event) {
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
    sdl2.RenderPresent(renderer)
    sdl2.Delay(16)
  }
}
