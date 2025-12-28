import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import shared/positive_float.{type PositiveFloat}

pub type RateResponse {
  RateResponse(
    from: Int,
    to: Int,
    rate: Option(PositiveFloat),
    source: Source,
    timestamp: Int,
  )
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
    #("rate", json.nullable(rate, positive_float.encode)),
    #("source", json.string(source_to_string(source))),
    #("timestamp", json.int(timestamp)),
  ])
}

pub fn decoder() -> Decoder(RateResponse) {
  let source_decoder =
    decode.then(decode.string, fn(decoded_string) {
      case decoded_string {
        "CoinMarketCap" -> decode.success(CoinMarketCap)
        "Kraken" -> decode.success(Kraken)
        _ -> decode.failure(CoinMarketCap, "Source")
      }
    })

  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use rate <- decode.field("rate", decode.optional(positive_float.decoder()))
  use source <- decode.field("source", source_decoder)
  use timestamp <- decode.field("timestamp", decode.int)
  decode.success(RateResponse(from:, to:, rate:, source:, timestamp:))
}
