import gleam/dynamic/decode.{type Decoder}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub fn decoder() -> Decoder(RateResponse) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use rate <- decode.field("rate", decode.float)
  decode.success(RateResponse(from:, to:, rate:))
}
