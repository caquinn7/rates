import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}

pub fn replace_state(state: Dynamic, url: Option(String)) -> Nil {
  do_replace_state(state, case url {
    None -> ""
    Some(url) -> url
  })
}

@external(javascript, "../../history_ffi.mjs", "replaceState")
fn do_replace_state(state: Dynamic, url: String) -> Nil
