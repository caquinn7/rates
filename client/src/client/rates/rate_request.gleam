import gleam/json.{type Json}
import shared/rates/rate_request.{type RateRequest, RateRequest}

pub fn encode(rate_request: RateRequest) -> Json {
  let RateRequest(from, to) = rate_request
  json.object([#("from", json.int(from)), #("to", json.int(to))])
}
