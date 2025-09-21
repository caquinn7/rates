import gleam/erlang/atom

pub fn monotonic_time_ms() -> Int {
  monotonic_time(millisecond())
}

pub fn system_time_ms() -> Int {
  system_time(millisecond())
}

fn millisecond() {
  atom.create("millisecond")
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom) -> Int

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom) -> Int
