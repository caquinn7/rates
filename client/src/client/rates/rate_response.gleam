import gleam/dynamic/decode.{type Decoder}
import shared/rates/rate_response.{
  type RateResponse, CoinMarketCap, Kraken, RateResponse,
}

pub fn decoder() -> Decoder(RateResponse) {
  let source_decoder = {
    use decoded_string <- decode.then(decode.string)
    case decoded_string {
      "CoinMarketCap" -> decode.success(CoinMarketCap)
      "Kraken" -> decode.success(Kraken)
      _ -> decode.failure(CoinMarketCap, "Source")
    }
  }

  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use rate <- decode.field("rate", decode.float)
  use source <- decode.field("source", source_decoder)
  decode.success(RateResponse(from:, to:, rate:, source:))
}
