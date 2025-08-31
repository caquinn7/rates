import gleam/json.{type Json}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub fn encode(rate_response: RateResponse) -> Json {
  let RateResponse(from:, to:, rate:, source:, timestamp:) = rate_response

  json.object([
    #("from", json.int(from)),
    #("to", json.int(to)),
    #("rate", json.float(rate)),
    #("source", json.string(rate_response.source_to_string(source))),
    #("timestamp", json.int(timestamp)),
  ])
}
