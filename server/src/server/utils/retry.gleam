import gleam/erlang/process

pub fn with_retry(
  operation: fn() -> Result(a, Nil),
  retries: Int,
  delay_ms: Int,
) -> Result(a, Nil) {
  case operation() {
    Ok(value) -> Ok(value)
    Error(_) if retries == 0 -> Error(Nil)
    Error(_) -> {
      process.sleep(delay_ms)
      with_retry(operation, retries - 1, delay_ms)
    }
  }
}
