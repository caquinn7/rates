import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom.{type Atom}
import gleam/result
import gleam/time/timestamp

/// Parses a provider's RFC3339 timestamp as Unix milliseconds. Fractional
/// precision beyond milliseconds is truncated; invalid timestamps return an error.
pub fn parse_rfc3339_ms(input: String) -> Result(Int, Nil) {
  use parsed <- result.map(timestamp.parse_rfc3339(input))

  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(parsed)

  { seconds * 1000 } + { nanoseconds / 1_000_000 }
}

/// Decodes an RFC3339 timestamp string into Unix milliseconds, truncating any
/// precision beyond milliseconds. Non-string values and invalid timestamps
/// produce decoding errors.
pub fn rfc3339_ms_decoder() -> Decoder(Int) {
  use timestamp <- decode.then(decode.string)
  case parse_rfc3339_ms(timestamp) {
    Ok(milliseconds) -> decode.success(milliseconds)
    Error(Nil) -> decode.failure(0, "RFC3339 timestamp")
  }
}

/// Returns Erlang's monotonic time in milliseconds for measuring elapsed time
/// and calculating timeout deadlines.
///
/// Values never decrease, even when the wall clock is adjusted. Their origin is
/// arbitrary; only differences between values from the same Erlang VM are meaningful.
pub fn monotonic_time_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int
