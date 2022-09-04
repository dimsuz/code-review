package main

import imgui "../odin-imgui"

div_by_float :: proc (v: imgui.Vec2, f: f32) -> imgui.Vec2 {
  return imgui.Vec2{ x = v.x / f, y = v.y /f }
}

div :: proc {div_by_float}

minus :: proc(v1: imgui.Vec2, v2: imgui.Vec2) -> imgui.Vec2 {
  return imgui.Vec2{v1.x - v2.x, v1.y - v2.y}
}

mul_by_float :: proc(v1: imgui.Vec2, f: f32) -> imgui.Vec2 {
  return imgui.Vec2{v1.x * f, v1.y * f}
}

mul :: proc {mul_by_float}
