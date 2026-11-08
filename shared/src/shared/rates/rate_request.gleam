import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

/// A request for the conversion rate of one unit of `from` into `to`.
pub type RateRequest {
  RateRequest(
    /// Source currency ID.
    from: Int,
    /// Target currency ID.
    to: Int,
  )
}

pub fn encode(rate_request: RateRequest) -> Json {
  let RateRequest(from, to) = rate_request
  json.object([#("from", json.int(from)), #("to", json.int(to))])
}

pub fn decoder() -> Decoder(RateRequest) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  decode.success(RateRequest(from:, to:))
}
