import gleam/erlang/atom.{type Atom}

pub fn monotonic_time_ms() -> Int {
  monotonic_time(millisecond())
}

pub fn system_time_ms() -> Int {
  system_time(millisecond())
}

fn millisecond() -> Atom {
  atom.create("millisecond")
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

@external(erlang, "erlang", "system_time")
fn system_time(unit: Atom) -> Int
