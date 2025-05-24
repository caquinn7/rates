import gleam/dynamic/decode.{type Decoder}
import shared/rates/rate_request.{type RateRequest, RateRequest}

pub fn decoder() -> Decoder(RateRequest) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  decode.success(RateRequest(from:, to:))
}
