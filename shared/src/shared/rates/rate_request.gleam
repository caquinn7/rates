import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type RateRequest {
  RateRequest(from: Int, to: Int)
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
