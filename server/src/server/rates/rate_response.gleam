import gleam/json.{type Json}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub fn encode(rate_response: RateResponse) -> Json {
  let RateResponse(from:, to:, rate:) = rate_response

  json.object([
    #("from", json.int(from)),
    #("to", json.int(to)),
    #("rate", json.float(rate)),
  ])
}
