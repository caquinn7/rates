import gleam/erlang/process
import gleam/result

pub fn attempt(
  operation: fn() -> Result(a, Nil),
  retries: Int,
  delay_ms: Int,
) -> Result(a, Nil) {
  result.lazy_or(operation(), fn() {
    case retries {
      0 -> Error(Nil)
      _ -> {
        process.sleep(delay_ms)
        attempt(operation, retries - 1, delay_ms)
      }
    }
  })
}
