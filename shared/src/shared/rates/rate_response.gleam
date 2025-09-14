import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type RateResponse {
  RateResponse(from: Int, to: Int, rate: Float, source: Source, timestamp: Int)
}

pub type Source {
  CoinMarketCap
  Kraken
}

pub fn source_to_string(source: Source) {
  case source {
    CoinMarketCap -> "CoinMarketCap"
    Kraken -> "Kraken"
  }
}

pub fn encode(rate_response: RateResponse) -> Json {
  let RateResponse(from:, to:, rate:, source:, timestamp:) = rate_response

  json.object([
    #("from", json.int(from)),
    #("to", json.int(to)),
    #("rate", json.float(rate)),
    #("source", json.string(source_to_string(source))),
    #("timestamp", json.int(timestamp)),
  ])
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
  use timestamp <- decode.field("timestamp", decode.int)
  decode.success(RateResponse(from:, to:, rate:, source:, timestamp:))
}
