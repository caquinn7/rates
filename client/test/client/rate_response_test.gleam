import client/rates/rate_response
import gleam/json
import gleeunit/should
import shared/rates/rate_response.{Kraken, RateResponse} as _shared_rate_response

pub fn decode_rate_response_json_test() {
  "{\"from\":1,\"to\":2781,\"rate\":100000.0,\"source\":\"Kraken\"}"
  |> json.parse(rate_response.decoder())
  |> should.be_ok
  |> should.equal(RateResponse(1, 2781, 100_000.0, Kraken))
}
