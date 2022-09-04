package main

import "core:time"
import "core:fmt"

@(deferred_in_out=print_duration)
scoped_measure_duration :: proc(label: string) -> time.Tick {
  return time.tick_now()
}

print_duration :: proc(label: string, start: time.Tick) {
  duration := time.tick_since(start)
  fmt.println(label, duration)
}
