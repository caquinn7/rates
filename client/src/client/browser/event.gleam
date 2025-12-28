import gleam/dynamic.{type Dynamic}

pub type Event

@external(javascript, "./event_ffi.mjs", "target")
pub fn target(event: Event) -> Dynamic
